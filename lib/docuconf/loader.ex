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

  `secret` is true for a secret `config` or `text` file; `inspect/2` then
  shows its `data` as `**redacted**`.
  """
  @type t :: %__MODULE__{
          name: String.t(),
          type: String.t(),
          path: String.t(),
          data: term(),
          secret: boolean()
        }
  defstruct [:name, :type, :path, :data, secret: false]

  defimpl Inspect do
    # The content of a secret config or text file is never printed.
    def inspect(%{secret: true} = f, opts),
      do: Docuconf.Redacted.inspect_struct(f, [:name, :type, :path, :data], [:data], opts)

    def inspect(f, opts),
      do: Docuconf.Redacted.inspect_struct(f, [:name, :type, :path, :data], [], opts)
  end
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
    {env, env_warnings} = environment(opts)
    opts = Keyword.put_new(opts, :file_root, Map.get(env, "DOCUCONF_FILE_ROOT"))

    # Profiles and overlays (contract-first mode only): the layers below
    # the environment, highest first.
    {layers, layer_violations, layer_warnings} =
      Docuconf.Layers.load(d, env, opts[:file_root])

    {vars, var_violations, warnings} =
      Enum.reduce(d.vars, {%{}, [], layer_warnings}, fn var, {vals, vios, warns} ->
        raw = raw_value(env, var)
        below = Map.get(layers, var.name, [])

        warns =
          if raw != nil and Enum.any?(below, &match?({:overlay, _, _}, &1)),
            do:
              warns ++
                [
                  "#{var.name} is set both in the environment and in an overlay; the environment wins"
                ],
            else: warns

        set? = raw != nil or Enum.any?(below, &(&1 == :bad or match?({:overlay, _, _}, &1)))

        # SPEC §4.2: a deprecated input that is set is a warning, naming
        # the input and its message, never the value.
        warns =
          if set? and var.deprecated,
            do: warns ++ [deprecation(var)],
            else: warns

        warns =
          if (is_binary(raw) or is_list(raw)) and var.secret and
               Enum.any?(List.wrap(raw), &String.ends_with?(&1, "\n")),
             do:
               warns ++
                 [
                   "#{var.name} ends with a newline; secrets created with --from-file often do (values are never trimmed)"
                 ],
             else: warns

        case layered(var, raw, below) do
          :bad -> {vals, vios, warns}
          {:ok, v} -> {Map.put(vals, var.name, v), vios, warns}
          {:error, code, msg} -> {vals, vios ++ [Violation.new(var.name, :var, code, msg)], warns}
        end
      end)

    var_violations = layer_violations ++ var_violations

    {files, file_violations} =
      Enum.reduce(d.files, {%{}, []}, fn f, {vals, vios} ->
        {value, vs} = Files.load(f, env, vars, opts)
        {Map.put(vals, f.field, value), vios ++ vs}
      end)

    warnings =
      env_warnings ++
        typo_warnings(d, env) ++
        warnings ++
        for f <- d.files,
            f.deprecated,
            File.exists?(Files.resolve_path(f, env, opts[:file_root])) do
          "file " <> deprecation(f)
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

  # The raw value of a variable: its env string, or the items of an indexed
  # list (NAME__0, NAME__1, ...). nil is unset. SPEC §5: only a decimal index
  # with no leading zero is an item (NAME__HOST is not), and items must be
  # numbered from 0 with no gap; a gap is `{:error, :invalid_type, message}`,
  # since a host that stops at it and one that skips it read different lists.
  @doc false
  def raw_value(env, %Var{type: t, encoding: "indexed", name: name})
      when t in ["list", "keySet"] do
    prefix = name <> "__"

    indexed =
      for {key, value} <- env,
          String.starts_with?(key, prefix),
          suffix = binary_part(key, byte_size(prefix), byte_size(key) - byte_size(prefix)),
          suffix =~ ~r/\A(?:0|[1-9][0-9]*)\z/,
          into: %{},
          do: {String.to_integer(suffix), value}

    count = map_size(indexed)

    case Enum.find(0..(count - 1)//1, &(not Map.has_key?(indexed, &1))) do
      nil when count == 0 ->
        nil

      nil ->
        Enum.map(0..(count - 1), &Map.fetch!(indexed, &1))

      missing ->
        found = indexed |> Map.keys() |> Enum.sort() |> Enum.map_join(", ", &"#{prefix}#{&1}")

        {:error, :invalid_type,
         "has items #{found} but no #{prefix}#{missing}; items must be numbered from 0 with no gap"}
    end
  end

  def raw_value(env, %Var{} = var) do
    case Map.get(env, var.name) do
      # SPEC §5: empty means unset for every type but string.
      "" when var.type != "string" -> nil
      raw -> raw
    end
  end

  defp deprecation(%{name: name, deprecated: d}) do
    instead = if d[:replaced_by], do: " (replaced by #{d.replaced_by})", else: ""
    "#{name} is deprecated#{instead}: #{d.message}"
  end

  # The environment, then each layer below it (an overlay, then the
  # selected profile), then the variable's own default.
  defp layered(var, raw, _below) when raw != nil, do: resolve(var, raw)
  defp layered(var, nil, []), do: resolve(var, nil)
  defp layered(_var, nil, [:bad | _]), do: :bad
  defp layered(_var, nil, [{:profile, _name, typed} | _]), do: {:ok, typed}

  defp layered(var, nil, [{:overlay, name, raw} | rest]) do
    # As for an env value, "" is unset for every type but string.
    if raw == "" and var.type != "string" do
      layered(var, nil, rest)
    else
      case resolve(var, raw) do
        {:error, code, msg} -> {:error, code, "from overlay #{name}: #{msg}"}
        ok -> ok
      end
    end
  end

  defp public(_var, nil), do: nil
  defp public(var, v), do: Value.to_public(var, v)

  defp resolve(_var, {:error, _code, _message} = error), do: error

  defp resolve(%Var{} = var, nil) do
    cond do
      var.required -> {:error, :missing_required, "required, but not set"}
      var.has_default -> {:ok, var.default}
      true -> {:ok, nil}
    end
  end

  defp resolve(%Var{secret: true} = var, raw) do
    case raw |> List.wrap() |> Enum.find_value(&injector_scheme/1) do
      nil ->
        Value.parse(var, raw)

      scheme ->
        {:error, :invalid_type,
         "holds an unresolved #{scheme} reference; the injector that should resolve it did not run"}
    end
  end

  defp resolve(%Var{} = var, raw), do: Value.parse(var, raw)

  # SPEC §4.5.1 and §11.2: platforms inject secrets (Bank-Vaults vault-env,
  # `op run`, vals) before the process starts. A secret that still holds a
  # reference means the injector did not run. The message names the scheme,
  # never the value.
  @injector_schemes ["vault:", "op://", "ref+"]

  @doc false
  def injector_scheme(raw) when is_binary(raw),
    do: Enum.find(@injector_schemes, &String.starts_with?(raw, &1))

  @doc false
  # The environment a load reads, lowest precedence first: `:fallback_env`,
  # the `.env` file, then the real environment (or `:env`). Returns
  # `{env, warnings}`. `nil` and `false` turn `:dotenv` and `:fallback_env`
  # off, so `dotenv: config_env() == :dev && ".env"` works.
  def environment(opts) do
    env = Keyword.get_lazy(opts, :env, &System.get_env/0)

    {dotenv, warnings} =
      case Keyword.get(opts, :dotenv) do
        off when off in [nil, false] ->
          {%{}, []}

        path when is_binary(path) ->
          if File.regular?(path),
            do: {Docuconf.Dotenv.read(path), []},
            else: {%{}, ["dotenv file #{path} does not exist; nothing was read from it"]}

        other ->
          raise ArgumentError,
                "docuconf: :dotenv must be a path, nil or false, got: #{inspect(other)}"
      end

    fallback =
      case Keyword.get(opts, :fallback_env) do
        off when off in [nil, false] ->
          %{}

        %{} = map ->
          Map.new(map, fn {k, v} -> {to_string(k), to_string(v)} end)

        other ->
          raise ArgumentError,
                "docuconf: :fallback_env must be a map of variable name to value, nil or false, got: " <>
                  inspect(other)
      end

    # Real environment variables override the .env file (SPEC §11.2 item 4).
    {fallback |> Map.merge(dotenv) |> Map.merge(env), warnings}
  end

  # SPEC-wide hint: a set variable that is not declared but is a likely typo
  # of a declared name. A warning only, and it never shows the value.
  defp typo_warnings(%Declaration{} = d, env) do
    declared = Enum.map(d.vars, & &1.name)
    path_envs = for f <- d.files, f.path_env, do: f.path_env

    for key <- env |> Map.keys() |> Enum.sort(),
        Regex.match?(~r/^[A-Z][A-Z0-9_]*\z/, key),
        key not in declared,
        key not in path_envs,
        not String.starts_with?(key, "DOCUCONF_"),
        not Enum.any?(declared, &String.starts_with?(key, &1 <> "__")),
        match = closest(key, declared) do
      "#{key} is set but not declared; did you mean #{match}?"
    end
  end

  defp closest(key, names) do
    names
    |> Enum.map(&{&1, distance(key, &1)})
    # Short names are close to many unrelated ones (HOST and PORT differ by
    # two letters), so they get a tighter limit.
    |> Enum.filter(fn {name, dist} -> dist <= if(String.length(name) >= 6, do: 2, else: 1) end)
    |> Enum.min_by(fn {_, dist} -> dist end, fn -> nil end)
    |> case do
      {name, _} -> name
      nil -> nil
    end
  end

  @doc false
  # Optimal string alignment distance: Levenshtein plus adjacent swaps, so
  # PROT is one edit from PORT.
  def distance(a, b) do
    a = String.graphemes(a) |> List.to_tuple()
    b = String.graphemes(b) |> List.to_tuple()
    {la, lb} = {tuple_size(a), tuple_size(b)}

    if abs(la - lb) > 2 do
      3
    else
      d =
        for i <- 0..la, j <- 0..lb, reduce: %{} do
          acc ->
            v =
              cond do
                i == 0 ->
                  j

                j == 0 ->
                  i

                true ->
                  cost = if elem(a, i - 1) == elem(b, j - 1), do: 0, else: 1

                  best =
                    Enum.min([
                      acc[{i - 1, j}] + 1,
                      acc[{i, j - 1}] + 1,
                      acc[{i - 1, j - 1}] + cost
                    ])

                  if i > 1 and j > 1 and elem(a, i - 1) == elem(b, j - 2) and
                       elem(a, i - 2) == elem(b, j - 1),
                     do: min(best, acc[{i - 2, j - 2}] + 1),
                     else: best
              end

            Map.put(acc, {i, j}, v)
        end

      d[{la, lb}]
    end
  end

  @doc """
  Writes the message to the Kubernetes termination log so `kubectl describe
  pod` shows it. `DOCUCONF_TERMINATION_LOG` overrides the path (and is
  written even if it does not exist yet); the default path is only written
  when it exists, that is inside a container. A load given `:env` writes
  none unless `:termination_log` is set. Best effort.
  """
  def write_termination_log(message, opts) do
    override =
      case Keyword.fetch(opts, :termination_log) do
        {:ok, v} ->
          v

        # A load from an explicit env map (a test) never writes the
        # process's termination log unless asked to.
        :error ->
          if Keyword.has_key?(opts, :env),
            do: false,
            else: System.get_env("DOCUCONF_TERMINATION_LOG")
      end

    target =
      cond do
        override == false -> nil
        is_binary(override) and override != "" -> override
        File.exists?(@termination_log) -> @termination_log
        true -> nil
      end

    if target do
      bin =
        if byte_size(message) > @termination_limit,
          do: binary_part(message, 0, @termination_limit),
          else: message

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
  A missing file is an empty environment (`Docuconf.load/2` warns about it).
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
    rest
    |> String.trim_trailing("\"")
    |> String.replace("\\n", "\n")
    |> String.replace("\\\"", "\"")
  end

  defp unquote_value("'" <> rest), do: String.trim_trailing(rest, "'")
  defp unquote_value(v), do: v |> String.split(~r/\s+#/, parts: 2) |> hd()
end
