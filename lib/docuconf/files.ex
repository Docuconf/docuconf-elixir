defmodule Docuconf.Files do
  @moduledoc false
  # Boot-time checks for file inputs (SPEC §11.2 item 7).

  alias Docuconf.{FileInput, JSONSchema, Keystore, RE2, TLS, Value}

  @type report :: (Docuconf.Violation.code(), String.t() -> :ok)

  @doc """
  Resolves where a file input is read from: the `path_env` variable when
  set, else the declared path; `file_root` is prefixed to absolute paths.
  """
  def resolve_path(%FileInput{} = f, env, file_root) do
    path =
      case f.path_env && Map.get(env, f.path_env) do
        p when is_binary(p) and p != "" -> p
        _ -> f.path
      end

    if file_root not in [nil, ""] and String.starts_with?(path, "/"),
      do: Path.join(file_root, path),
      else: path
  end

  @doc """
  Checks one file input. Returns `{value, violations}`, where `value` is a
  `Docuconf.LoadedFile` or `nil` when an optional input is absent.
  `vars` holds the already parsed variables, by env name (for `password_var`).
  """
  def load(%FileInput{} = f, env, vars, opts) do
    path = resolve_path(f, env, Keyword.get(opts, :file_root))
    key = {__MODULE__, make_ref()}
    Process.put(key, [])

    report = fn code, msg ->
      Process.put(key, [Docuconf.Violation.new(f.name, :file, code, msg) | Process.get(key)])
      :ok
    end

    value = check(f, path, vars, report, opts)
    violations = key |> Process.delete() |> Enum.reverse()
    {if(violations == [], do: value), violations}
  end

  defp check(%FileInput{type: "tls"} = f, dir, _vars, report, opts) do
    case File.stat(dir) do
      {:error, :enoent} ->
        if f.required, do: report.(:file_missing, "#{dir} not found")
        nil

      {:error, reason} ->
        report.(:file_unreadable, "#{dir} cannot be accessed (#{reason})#{hint(reason)}")
        nil

      {:ok, %File.Stat{type: :directory}} ->
        TLS.check(f, dir, report, opts)

      {:ok, _} ->
        report.(:file_malformed, "#{dir} must be a directory holding tls.crt and tls.key")
        nil
    end
  end

  defp check(%FileInput{} = f, path, vars, report, opts) do
    case stat(f, path, report) do
      :absent ->
        nil

      :error ->
        nil

      {:ok, _size} when f.type == "binary" ->
        case File.open(path, [:read, :binary], fn _ -> :ok end) do
          {:ok, :ok} -> loaded(f, path, nil)
          {:error, reason} -> unreadable(report, path, reason)
        end

      {:ok, _size} ->
        case File.read(path) do
          {:ok, content} -> content(f, path, content, vars, report, opts)
          {:error, reason} -> unreadable(report, path, reason)
        end
    end
  end

  defp stat(f, path, report) do
    case File.stat(path) do
      {:error, :enoent} ->
        if f.required, do: report.(:file_missing, "#{path} not found")
        :absent

      {:error, reason} ->
        report.(:file_unreadable, "#{path} cannot be accessed (#{reason})#{hint(reason)}")
        :error

      {:ok, %File.Stat{type: :directory}} ->
        report.(:file_malformed, "#{path} is a directory, expected a file")
        :error

      {:ok, %File.Stat{size: size}} ->
        if f.max_size && size > f.max_size do
          report.(:file_too_large, "#{path} is #{size} bytes, more than maxSize #{f.max_size}")
          :error
        else
          {:ok, size}
        end
    end
  end

  defp unreadable(report, path, reason) do
    report.(:file_unreadable, "#{path} cannot be read (#{reason})#{hint(reason)}")
    nil
  end

  @doc false
  def hint(:eacces),
    do: "; a non-root container needs the pod's fsGroup set to read 0400 secret volumes"

  def hint(_), do: ""

  defp content(%FileInput{type: "config"} = f, path, content, _vars, report, _opts) do
    content = strip_bom(content)

    case decode(f, content) do
      {:ok, data} ->
        case f.schema && JSONSchema.validate(data, f.schema) do
          problems when problems in [nil, []] ->
            loaded(f, path, JSONSchema.bind(data, f.spec || %{}))

          problems ->
            problems =
              if f.secret,
                do: Enum.map(problems, &(&1 |> String.split(":") |> hd())),
                else: problems

            report.(
              :schema_mismatch,
              "#{path} does not match its schema: " <> Enum.join(problems, "; ")
            )

            nil
        end

      {:error, detail} ->
        detail = if f.secret, do: "", else: " (#{detail})"
        report.(:file_malformed, "#{path} is not valid #{String.upcase(f.format)}#{detail}")
        nil
    end
  end

  defp content(%FileInput{type: "text"} = f, path, content, _vars, report, _opts) do
    len = if String.valid?(content), do: String.length(content), else: 0

    problem =
      cond do
        not String.valid?(content) ->
          {:file_malformed, "#{path} is not valid UTF-8 text"}

        f.min_length && len < f.min_length ->
          {:out_of_range,
           "#{path}: content is #{len} characters, shorter than minLength #{f.min_length}"}

        f.max_length && len > f.max_length ->
          {:out_of_range,
           "#{path}: content is #{len} characters, longer than maxLength #{f.max_length}"}

        f.pattern && not RE2.matches?(f.pattern, content) ->
          {:pattern_mismatch, "#{path}: content does not match pattern #{inspect(f.pattern)}"}

        true ->
          nil
      end

    case problem do
      nil ->
        loaded(f, path, content)

      {code, msg} ->
        report.(code, msg)
        nil
    end
  end

  defp content(%FileInput{type: "caBundle"} = f, path, content, _vars, report, _opts) do
    certs = TLS.pem_certificates(content)
    good = Enum.filter(certs, &match?({:ok, _}, &1))

    cond do
      certs == [] ->
        report.(:file_malformed, "#{path} holds no PEM certificate")
        nil

      length(good) < length(certs) ->
        report.(
          :file_malformed,
          "#{path}: #{length(certs) - length(good)} certificate(s) cannot be parsed"
        )

        nil

      length(good) < f.min_certificates ->
        report.(
          :file_malformed,
          "#{path} holds #{length(good)} certificate(s), needs at least #{f.min_certificates}"
        )

        nil

      true ->
        loaded(f, path, Enum.map(good, fn {:ok, der} -> der end))
    end
  end

  defp content(%FileInput{type: "keystore"} = f, path, content, vars, report, _opts) do
    password =
      case f.password_var && Map.get(vars, f.password_var) do
        p when is_binary(p) -> p
        _ -> ""
      end

    case Keystore.verify(f.format, content, password) do
      :ok ->
        loaded(f, path, nil)

      {:error, reason} ->
        via = if f.password_var, do: " with the password from #{f.password_var}", else: ""

        report.(
          :keystore_unreadable,
          "#{path}: cannot open the #{f.format} keystore#{via} (#{reason})"
        )

        nil
    end
  end

  defp decode(%FileInput{format: "json", decoder: nil}, content) do
    case JSON.decode(content) do
      {:ok, v} -> {:ok, v}
      {:error, reason} -> {:error, Value.json_error(reason)}
    end
  end

  defp decode(%FileInput{decoder: decoder}, content) do
    result =
      try do
        case decoder do
          {m, fun} -> apply(m, fun, [content])
          fun -> fun.(content)
        end
      rescue
        e -> {:error, Exception.message(e)}
      end

    case result do
      {:ok, v} -> {:ok, v}
      {:error, %{__exception__: true} = e} -> {:error, Exception.message(e)}
      {:error, reason} -> {:error, if(is_binary(reason), do: reason, else: inspect(reason))}
      other -> {:error, "decoder returned #{inspect(other, limit: 3)}, expected {:ok, data}"}
    end
  end

  defp strip_bom(<<0xEF, 0xBB, 0xBF, rest::binary>>), do: rest
  defp strip_bom(s), do: s

  defp loaded(f, path, data),
    do: %Docuconf.LoadedFile{name: f.name, type: f.type, path: path, data: data}
end
