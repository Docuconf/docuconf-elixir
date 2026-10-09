defmodule Docuconf.Contract do
  @moduledoc """
  Contract-first mode (SPEC §11.2 item 11): validate an environment against
  a contract given as JSON (`cue export contract.cue --out json`), with no
  `use Docuconf` declaration.

      {:ok, values} =
        Docuconf.Contract.load(File.read!("contract.json"), env: System.get_env())

      values["PORT"]          #=> 8080
      values["serving-tls"]   #=> %Docuconf.LoadedFile{...}

  `values` is a `Docuconf.Contract.Values`: read it with `values["PORT"]`
  (`Access`) or turn it into a plain map with
  `Docuconf.Contract.Values.to_map/1`. Inspecting it shows secrets as
  `**redacted**`.

  The contract is turned into the same declaration the DSL builds, so it
  goes through the same declaration checks, parsers and constraint checks
  as `use Docuconf`. Values are keyed by variable name (`"PORT"`) and file
  input name (`"serving-tls"`); absent optional inputs are `nil`.

  Every list and key set encoding (`csv`, `json`, `indexed`) and duration
  encoding (`go`, `iso8601`, `seconds`, `timespan`) is parsed, by the exact
  rules of SPEC §5. Durations are integers in `:duration_unit`:
  milliseconds by default, as in the DSL. A `keySet` is a
  `Docuconf.KeySet`.

  File inputs are read under `DOCUCONF_FILE_ROOT` (or `:file_root`): `config`
  files in `json`, `yaml` and `toml` (with the built-in `Docuconf.YAML` and
  `Docuconf.TOML` readers, or a decoder of your own in `:decoders`), `tls`
  key pairs, `caBundle`s, PKCS#12 `keystore`s, `text` and `binary` files.

  Profiles (SPEC §4.4) and config-file overlays (SPEC §4.7) are layered as a
  host that reads config files would: a variable's default, then the
  selected profile's default, then an overlay (read from its `path` under
  the file root; a missing one is not an error), then the environment.
  Elixir's own `config/*.exs` files are compiled into the release, so the
  `use Docuconf` DSL has neither.

  Not supported: `reload: "watch"`, on a file input or an overlay
  (contract-first mode starts no watcher, so it rejects the promise rather
  than break it).
  """

  alias Docuconf.{Declaration, DeclarationError, Loader, ValidationError}

  @var_keys %{
    "description" => :description,
    "details" => :details,
    "required" => :required,
    "secret" => :secret,
    "default" => :default,
    "group" => :group,
    "examples" => :examples,
    "configKey" => :config_key,
    "min" => :min,
    "max" => :max,
    "minLength" => :min_length,
    "maxLength" => :max_length,
    "pattern" => :pattern,
    "values" => :values,
    "schemes" => :schemes,
    "separator" => :separator,
    "minItems" => :min_items,
    "maxItems" => :max_items,
    "itemMin" => :item_min,
    "itemMax" => :item_max,
    "itemMinLength" => :item_min_length,
    "itemMaxLength" => :item_max_length,
    "minKeys" => :min_keys,
    "maxKeys" => :max_keys,
    "keyMinLength" => :key_min_length,
    "keyMaxLength" => :key_max_length,
    "encoding" => :encoding,
    "schema" => :schema
  }

  @file_keys %{
    "description" => :description,
    "details" => :details,
    "required" => :required,
    "secret" => :secret,
    "path" => :path,
    "pathEnv" => :path_env,
    "reload" => :reload,
    "maxSize" => :max_size,
    "group" => :group,
    "format" => :format,
    "schema" => :schema,
    "dnsNames" => :dns_names,
    "keyAlgorithms" => :key_algorithms,
    "minRemaining" => :min_remaining,
    "requireCA" => :require_ca,
    "minCertificates" => :min_certificates,
    "passwordVar" => :password_var,
    "pattern" => :pattern,
    "minLength" => :min_length,
    "maxLength" => :max_length
  }

  @types %{
    "string" => :string,
    "int" => :integer,
    "float" => :float,
    "bool" => :boolean,
    "duration" => :duration,
    "url" => :url,
    "enum" => :enum,
    "json" => :json,
    "keySet" => :key_set
  }

  @doc """
  Turns a contract (a JSON string or a decoded map) into a checked
  declaration. Options: `:duration_unit` (default `:millisecond`; see the
  `unit` option of `Docuconf.env/3`) and `:decoders`, a map from config
  file or overlay format (`"yaml"`, `"toml"`, `"json"`) to a decoder
  function returning `{:ok, data}`, in place of the built-in reader.
  """
  @spec parse(String.t() | map(), keyword()) :: {:ok, Declaration.t()} | {:error, [String.t()]}
  def parse(contract, opts \\ [])

  def parse(json, opts) when is_binary(json) do
    case JSON.decode(json) do
      {:ok, %{} = map} -> parse(map, opts)
      {:ok, _} -> {:error, ["the contract must be a JSON object"]}
      {:error, reason} -> {:error, ["the contract is not valid JSON (#{inspect(reason)})"]}
    end
  end

  def parse(%{} = c, opts) do
    vars = Map.get(c, "vars") || %{}
    files = Map.get(c, "files") || %{}

    header =
      [
        {c["apiVersion"] != "docuconf.dev/v1alpha1", "apiVersion must be docuconf.dev/v1alpha1"},
        {c["kind"] != "ConfigContract", "kind must be ConfigContract"},
        {not is_map(vars), "vars must be an object"},
        {not is_map(files), "files must be an object"}
      ]
      |> Enum.flat_map(fn {bad, msg} -> if bad, do: [msg], else: [] end)

    if header != [] do
      {:error, header}
    else
      {var_decls, var_problems} =
        vars |> Enum.sort() |> Enum.map(&var_decl(&1, opts)) |> split()

      {file_decls, file_problems} =
        files |> Enum.sort() |> Enum.map(&file_decl(&1, opts)) |> split()

      name = get_in(c, ["metadata", "name"])
      version = get_in(c, ["metadata", "appVersion"])

      translated = var_problems ++ file_problems

      case Declaration.build(
             [name: name, app_version: version, origin: :contract],
             var_decls,
             file_decls
           ) do
        {:ok, decl} ->
          {profiles, p1} = Docuconf.Layers.parse_profiles(c["profiles"], decl.vars)

          {overlays, p2} =
            Docuconf.Layers.parse_overlays(c["overlays"], decl.files, opts[:decoders])

          case translated ++ p1 ++ p2 do
            [] -> {:ok, %{decl | profiles: profiles, overlays: overlays}}
            ps -> {:error, ps}
          end

        {:error, ps} ->
          {:error, translated ++ ps}
      end
    end
  end

  def parse(_other, _opts), do: {:error, ["the contract must be a JSON string or a map"]}

  defp split(results) do
    {for({:ok, d} <- results, do: d), Enum.flat_map(results, &problems/1)}
  end

  defp problems({:error, ps}), do: ps
  defp problems({:ok, _}), do: []

  # A variable becomes the {field, type, opts} tuple the DSL produces. The
  # field is the env name itself, so values come back keyed by it.
  defp var_decl({name, %{} = v}, opts) do
    with {:ok, type} <- var_type(name, v),
         {:ok, var_opts} <- translate("env #{name}", v, @var_keys, ["name", "type", "items"]) do
      var_opts =
        var_opts
        |> Keyword.put(:name, name)
        |> deprecated(v)
        |> then(fn o ->
          if v["type"] == "duration",
            do: Keyword.put(o, :unit, Keyword.get(opts, :duration_unit, :millisecond)),
            else: o
        end)

      {:ok, {name, type, var_opts}}
    end
  end

  defp var_decl({name, _}, _opts), do: {:error, ["env #{name}: must be an object"]}

  defp var_type(_name, %{"type" => "list", "items" => "string"}),
    do: {:ok, {:list, :string}}

  defp var_type(_name, %{"type" => "list", "items" => "int"}), do: {:ok, {:list, :integer}}

  defp var_type(name, %{"type" => "list"}),
    do: {:error, ["env #{name}: items must be \"string\" or \"int\""]}

  defp var_type(name, %{"type" => t}) do
    case Map.fetch(@types, t) do
      {:ok, type} -> {:ok, type}
      :error -> {:error, ["env #{name}: unknown type #{inspect(t)}"]}
    end
  end

  defp var_type(name, _), do: {:error, ["env #{name}: type is required"]}

  defp file_decl({name, %{} = f}, opts) do
    type = f["type"]

    with :ok <-
           if(type in ~w(config tls caBundle keystore text binary),
             do: :ok,
             else: {:error, :type}
           ),
         :ok <- if(f["reload"] == "watch", do: {:error, :watch}, else: :ok),
         {:ok, file_opts} <- translate("file #{name}", f, @file_keys, ["name", "type"]) do
      file_opts =
        file_opts
        |> Keyword.put(:name, name)
        |> deprecated(f)
        # tls and keystore inputs are always secret; the DSL rejects an
        # explicit secret option on them.
        |> then(&if(type in ["tls", "keystore"], do: Keyword.delete(&1, :secret), else: &1))
        |> decoder(type, f["format"], Keyword.get(opts, :decoders, %{}))

      {:ok, {name, type, file_opts}}
    else
      {:error, :type} ->
        {:error, ["file #{name}: unknown type #{inspect(type)}"]}

      {:error, :watch} ->
        {:error, ["file #{name}: reload \"watch\" is not supported in contract-first mode"]}

      {:error, ps} ->
        {:error, ps}
    end
  end

  defp file_decl({name, _}, _opts), do: {:error, ["file #{name}: must be an object"]}

  defp decoder(opts, "config", format, decoders) when format in ["yaml", "toml"],
    do: Keyword.put(opts, :decoder, decoder_for(format, decoders))

  defp decoder(opts, _type, _format, _decoders), do: opts

  @doc false
  # The decoder for a structured format: the caller's from `:decoders`, else
  # the built-in reader (Docuconf.YAML, Docuconf.TOML, Elixir's JSON).
  def decoder_for(format, decoders) do
    case Map.get(decoders || %{}, format) do
      nil -> builtin_decoder(format)
      fun -> fun
    end
  end

  defp builtin_decoder("yaml"), do: &Docuconf.YAML.decode/1
  defp builtin_decoder("toml"), do: &Docuconf.TOML.decode/1
  defp builtin_decoder("json"), do: &JSON.decode/1

  defp translate(label, map, keys, ignored) do
    {known, unknown} =
      map
      |> Map.drop(["deprecated" | ignored])
      |> Enum.split_with(fn {k, _} -> Map.has_key?(keys, k) end)

    if unknown == [] do
      {:ok, Enum.map(known, fn {k, v} -> {Map.fetch!(keys, k), v} end)}
    else
      {:error, ["#{label}: unknown fields #{unknown |> Enum.map(&elem(&1, 0)) |> inspect()}"]}
    end
  end

  defp deprecated(opts, %{"deprecated" => %{"message" => m} = d}),
    do: Keyword.put(opts, :deprecated, message: m, replaced_by: d["replacedBy"])

  defp deprecated(opts, _), do: opts

  @doc """
  Loads and validates an environment against a contract (a JSON string, a
  decoded map, or a declaration from `parse/2`).

  Returns `{:ok, values}`, a `Docuconf.Contract.Values` from variable and
  file input name to its typed value, or `{:error, %Docuconf.ValidationError{}}` listing every
  violation. An invalid contract returns `{:error, %Docuconf.DeclarationError{}}`.

  Takes the options of `parse/2` and of `Docuconf.load/2`: `:env`,
  `:dotenv`, `:file_root`, `:termination_log`, `:now` and `:warn`.
  """
  @spec load(String.t() | map() | Declaration.t(), keyword()) ::
          {:ok, Docuconf.Contract.Values.t()}
          | {:error, ValidationError.t() | DeclarationError.t()}
  def load(contract, opts \\ [])

  def load(%Declaration{} = decl, opts) do
    {result, warnings} =
      case Loader.run(decl, opts) do
        {:ok, values, warnings} ->
          by_name =
            Map.new(decl.vars, &{&1.name, Map.get(values, &1.field)})
            |> Map.merge(Map.new(decl.files, &{&1.name, Map.get(values, &1.field)}))

          secrets =
            for(v <- decl.vars, v.secret, do: v.name) ++
              for f <- decl.files, Docuconf.FileInput.secret_data?(f), do: f.name

          {{:ok, %Docuconf.Contract.Values{values: by_name, secrets: secrets}}, warnings}

        {:error, violations, warnings} ->
          e = %ValidationError{violations: violations}
          Loader.write_termination_log(Exception.message(e), opts)
          {{:error, e}, warnings}
      end

    if Keyword.get(opts, :warn, true) do
      for w <- warnings, do: IO.puts(:stderr, "docuconf: warning: " <> w)
    end

    result
  end

  def load(contract, opts) do
    case parse(contract, opts) do
      {:ok, decl} -> load(decl, opts)
      {:error, problems} -> {:error, %DeclarationError{module: nil, problems: problems}}
    end
  end

  @doc "Like `load/2`, but raises `Docuconf.ValidationError` or `Docuconf.DeclarationError`."
  @spec load!(String.t() | map() | Declaration.t(), keyword()) :: Docuconf.Contract.Values.t()
  def load!(contract, opts \\ []) do
    case load(contract, opts) do
      {:ok, values} -> values
      {:error, e} -> raise e
    end
  end
end
