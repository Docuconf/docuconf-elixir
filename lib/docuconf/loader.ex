defmodule Docuconf.LoadedFile do
  @moduledoc """
  A file input that passed its boot checks.

  `path` is where it was read (after `path_env` and `DOCUCONF_FILE_ROOT`).
  `data` depends on the type:

    * `config`: the decoded document, bound to the keyword spec when the
      schema was given as one (keys become atoms);
    * `tls`: a map with `:certfile`, `:keyfile`, `:cacertfile` (paths, ready
      for `:ssl` options), `:certificate` (leaf DER), `:chain`, `:cacerts`
      (DER list or nil) and `:not_after` (`DateTime`);
    * `caBundle`: the list of certificates as DER, ready for `cacerts:`;
    * `text`: the file's content;
    * `keystore`, `binary`: `nil` (read the file at `path` yourself).
  """
  @type t :: %__MODULE__{name: String.t(), type: String.t(), path: String.t(), data: term()}
  defstruct [:name, :type, :path, :data]
end

defmodule Docuconf.Loader do
  @moduledoc false

  alias Docuconf.{Declaration, Files, Value, Var, Violation}

  @termination_log "/dev/termination-log"
  # Kubernetes reads at most 4096 bytes of the termination message.
  @termination_limit 4096

  @doc """
  Loads and validates. Returns `{:ok, values, warnings}` with `values` a map
  of field => public value, or `{:error, violations, warnings}`.
  """
  def run(%Declaration{} = d, opts) do
    env = environment(opts)
    opts = Keyword.put_new(opts, :file_root, Map.get(env, "DOCUCONF_FILE_ROOT"))

    {vars, var_violations, warnings} =
      Enum.reduce(d.vars, {%{}, [], []}, fn var, {vals, vios, warns} ->
        raw = Map.get(env, var.name)
        # SPEC §5: empty means unset for every type but string.
        raw = if raw == "" and var.type != "string", do: nil, else: raw

        warns =
          if raw != nil and var.deprecated,
            do: warns ++ ["#{var.name} is deprecated: #{var.deprecated.message}"],
            else: warns

        warns =
          if raw != nil and var.secret and String.ends_with?(raw, "\n"),
            do: warns ++ ["#{var.name} ends with a newline; secrets created with --from-file often do (values are never trimmed)"],
            else: warns

        case resolve(var, raw) do
          {:ok, v} -> {Map.put(vals, var.name, v), vios, warns}
          {:error, code, msg} -> {vals, vios ++ [Violation.new(var.name, :var, code, msg)], warns}
        end
      end)

    {files, file_violations} =
      Enum.reduce(d.files, {%{}, []}, fn f, {vals, vios} ->
        {value, vs} = Files.load(f, env, vars, opts)
        {Map.put(vals, f.field, value), vios ++ vs}
      end)

    warnings =
      warnings ++
        for f <- d.files, f.deprecated, File.exists?(Files.resolve_path(f, env, opts[:file_root])) do
          "file #{f.name} is deprecated: #{f.deprecated.message}"
        end

    case var_violations ++ file_violations do
      [] ->
        values =
          d.vars
          |> Map.new(fn var -> {var.field, public(var, Map.get(vars, var.name))} end)
          |> Map.merge(files)

        {:ok, values, warnings}

      violations ->
        {:error, violations, warnings}
    end
  end

  defp public(_var, nil), do: nil
  defp public(var, v), do: Value.to_public(var, v)

  defp resolve(%Var{} = var, nil) do
    cond do
      var.required -> {:error, :missing_required, "required, but not set"}
      var.has_default -> {:ok, var.default}
      true -> {:ok, nil}
    end
  end

  defp resolve(%Var{} = var, raw), do: Value.parse(var, raw)

  defp environment(opts) do
    env = Keyword.get_lazy(opts, :env, &System.get_env/0)

    case Keyword.get(opts, :dotenv) do
      nil -> env
      # Real environment variables override the .env file (SPEC §11.2 item 4).
      path -> Map.merge(Docuconf.Dotenv.read(path), env)
    end
  end

  @doc """
  Writes the message to the Kubernetes termination log so `kubectl describe
  pod` shows it. `DOCUCONF_TERMINATION_LOG` overrides the path (and is
  written even if it does not exist yet); the default path is only written
  when it exists, that is inside a container. Best effort.
  """
  def write_termination_log(message, opts) do
    override =
      case Keyword.fetch(opts, :termination_log) do
        {:ok, v} -> v
        :error -> System.get_env("DOCUCONF_TERMINATION_LOG")
      end

    target =
      cond do
        override == false -> nil
        is_binary(override) and override != "" -> override
        File.exists?(@termination_log) -> @termination_log
        true -> nil
      end

    if target do
      bin = if byte_size(message) > @termination_limit, do: binary_part(message, 0, @termination_limit), else: message
      _ = File.write(target, bin)
    end

    :ok
  end
end

defmodule Docuconf.Dotenv do
  @moduledoc """
  A minimal `.env` reader for local development (opt-in with
  `dotenv: ".env"`). Supports `KEY=value`, `export KEY=value`, comments,
  and single- or double-quoted values (double quotes understand `\\n`).
  A missing file is an empty environment.
  """

  @spec read(Path.t()) :: %{String.t() => String.t()}
  def read(path) do
    case File.read(path) do
      {:ok, content} -> parse(content)
      {:error, _} -> %{}
    end
  end

  @doc false
  def parse(content) do
    content
    |> String.split(~r/\r?\n/)
    |> Enum.flat_map(fn line ->
      line = String.trim_leading(line)

      case Regex.run(~r/^(?:export\s+)?([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*)\z/, line) do
        [_, key, value] -> [{key, unquote_value(String.trim_trailing(value))}]
        _ -> []
      end
    end)
    |> Map.new()
  end

  defp unquote_value("\"" <> rest) do
    rest |> String.trim_trailing("\"") |> String.replace("\\n", "\n") |> String.replace("\\\"", "\"")
  end

  defp unquote_value("'" <> rest), do: String.trim_trailing(rest, "'")
  defp unquote_value(v), do: v |> String.split(~r/\s+#/, parts: 2) |> hd()
end
