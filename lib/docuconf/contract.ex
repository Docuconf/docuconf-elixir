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

  An input with `requiredIf: {VAR: value}` (SPEC §4.2.1) is required while
  the condition variable's loaded value (the environment, an overlay, the
  selected profile or its default) is that value: `CA_SUBJECT: is required
  when TLS_ENABLED is true`, the value written as JSON. A condition variable
  with a violation of its own makes nothing required. In a contract with
  `roles` (SPEC §4.9), the workload's role is `DOCUCONF_ROLE`, and an input
  whose `roles` leave it out is optional: with no role, or one the contract
  does not declare, only the inputs every role uses are required. A
  fragment's variables (`includes`, SPEC §4.8) are in the contract inline
  and read like any other; `parse/2` returns the declaration with
  `includes` and `roles`.

  Not supported: `reload: "watch"`, on a file input or an overlay
  (contract-first mode starts no watcher, so it rejects the promise rather
  than break it).
  """

  alias Docuconf.{Declaration, DeclarationError, Loader, ValidationError, Value, Var}

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

  # Fields read apart from the options: requiredIf and roles are read by
  # extras/2 and checked against the whole contract.
  @var_ignored ["name", "type", "items", "requiredIf", "roles"]
  @file_ignored ["name", "type", "requiredIf", "roles"]

  # SPEC §4.9: the variable that names the workload's role.
  @role_var "DOCUCONF_ROLE"

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

      # requiredIf (SPEC §4.2.1), roles (SPEC §4.9) and includes (SPEC §4.8).
      {includes, p_includes} = includes(c["includes"])
      {roles, p_roles} = roles(c["roles"], "roles")
      {var_extras, p_vars} = extras(vars, "env")
      {file_extras, p_files} = extras(files, "file")

      translated = var_problems ++ file_problems ++ p_includes ++ p_roles ++ p_vars ++ p_files

      case Declaration.build(
             [name: name, app_version: version, origin: :contract],
             var_decls,
             file_decls
           ) do
        {:ok, decl} ->
          {profiles, p1} = Docuconf.Layers.parse_profiles(c["profiles"], decl.vars)

          {overlays, p2} =
            Docuconf.Layers.parse_overlays(c["overlays"], decl.files, opts[:decoders])

          decl = %{
            decl
            | vars: with_extras(decl.vars, var_extras),
              files: with_extras(decl.files, file_extras),
              roles: roles,
              includes: includes
          }

          p3 = check_roles(decl, vars) ++ check_conditions(decl)

          case translated ++ p1 ++ p2 ++ p3 do
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
         {:ok, var_opts} <- translate("env #{name}", v, @var_keys, @var_ignored) do
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
         {:ok, file_opts} <- translate("file #{name}", f, @file_keys, @file_ignored) do
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

  # ---- requiredIf, roles and includes ------------------------------------------

  # The well-known fragments the contract includes (SPEC §4.8), name@major.
  # Their variables are in vars, inline, and read like any other.
  defp includes(nil), do: {[], []}

  defp includes(list) when is_list(list) do
    if Enum.all?(list, &is_binary/1) do
      problems =
        Enum.flat_map(Enum.with_index(list), fn {f, i} ->
          cond do
            not Regex.match?(~r/^[a-z][a-z0-9-]*@[1-9][0-9]*\z/, f) ->
              ["includes: #{inspect(f)} is not a fragment name, name@major"]

            f in Enum.take(list, i) ->
              ["includes: #{f} is listed twice"]

            true ->
              []
          end
        end)

      {Enum.uniq(list), problems}
    else
      includes(:not_a_list)
    end
  end

  defp includes(_other), do: {[], ["includes must be a list of fragment names, such as otel@1"]}

  # A list of roles (SPEC §4.9): DNS labels, at least one, none listed twice.
  defp roles(nil, _what), do: {nil, []}

  defp roles([_ | _] = list, what) do
    if Enum.all?(list, &is_binary/1) do
      problems =
        Enum.flat_map(Enum.with_index(list), fn {r, i} ->
          cond do
            not Regex.match?(~r/^[a-z0-9]([-a-z0-9]{0,61}[a-z0-9])?\z/, r) ->
              ["#{what}: role #{inspect(r)} must be a DNS label"]

            r in Enum.take(list, i) ->
              ["#{what}: role #{r} is listed twice"]

            true ->
              []
          end
        end)

      {list, problems}
    else
      roles(:not_a_list, what)
    end
  end

  defp roles(_other, what), do: {nil, ["#{what} must be a list of at least one role name"]}

  # Each input's requiredIf and roles, by name, as the fields of its
  # Docuconf.Var or Docuconf.FileInput.
  defp extras(inputs, kind) when is_map(inputs) do
    inputs
    |> Enum.sort()
    |> Enum.filter(fn {_name, input} -> is_map(input) end)
    |> Enum.map_reduce([], fn {name, input}, acc ->
      label = "#{kind} #{name}"
      {required_if, p1} = required_if(label, input)
      {roles, p2} = roles(input["roles"], "#{label}: roles")
      {{name, %{required_if: required_if, roles: roles}}, acc ++ p1 ++ p2}
    end)
    |> then(fn {pairs, problems} -> {Map.new(pairs), problems} end)
  end

  defp extras(_inputs, _kind), do: {%{}, []}

  defp with_extras(inputs, extras),
    do: Enum.map(inputs, &Map.merge(&1, Map.get(extras, &1.name, %{})))

  # requiredIf: {VAR: value} (SPEC §4.2.1): one variable and a string, an
  # integer or a boolean, as {name, value}. The input it makes required is
  # otherwise optional: not required, with no default, and not deprecated.
  defp required_if(_label, %{"requiredIf" => nil}), do: {nil, []}

  defp required_if(label, %{"requiredIf" => %{} = condition} = input)
       when map_size(condition) == 1 do
    [{name, value}] = Map.to_list(condition)
    plain? = is_binary(value) or is_integer(value) or is_boolean(value)

    if is_binary(name) and plain? and Regex.match?(~r/^[A-Z][A-Z0-9_]*\z/, name) do
      problems =
        [
          {input["required"] == true or input["default"] != nil,
           "an input with requiredIf is neither required nor has a default"},
          {input["deprecated"] != nil, "a conditionally required input cannot be deprecated"}
        ]
        |> Enum.flat_map(fn {bad, msg} -> if bad, do: ["#{label}: #{msg}"], else: [] end)

      {{name, value}, problems}
    else
      {nil, ["#{label}: requiredIf must name one variable and a string, int or bool value"]}
    end
  end

  defp required_if(label, %{"requiredIf" => _}),
    do: {nil, ["#{label}: requiredIf must name one variable and its value: {VAR: value}"]}

  defp required_if(_label, _input), do: {nil, []}

  # The inputs' roles against the contract's (SPEC §4.9), and DOCUCONF_ROLE:
  # a required enum whose values are exactly the roles, used by every role.
  defp check_roles(%Declaration{roles: roles} = decl, vars) do
    inputs =
      Enum.map(decl.vars, &{"env #{&1.name}", &1.roles}) ++
        Enum.map(decl.files, &{"file #{&1.name}", &1.roles})

    input_problems =
      Enum.flat_map(inputs, fn
        {_label, nil} ->
          []

        {label, _used} when roles == nil ->
          ["#{label}: has roles, but the contract declares none"]

        {label, used} ->
          for r <- used, r not in roles do
            "#{label}: role #{r} is not one of the contract's roles, #{Enum.join(roles, ", ")}"
          end
      end)

    role_var_problems =
      if roles == nil or role_var?(vars[@role_var], roles) do
        []
      else
        [
          "env #{@role_var}: a contract with roles declares it as a required enum whose " <>
            "values are the roles, #{Enum.join(roles, ", ")}, used by every role"
        ]
      end

    input_problems ++ role_var_problems
  end

  defp role_var?(%{"type" => "enum", "required" => true, "values" => values} = var, roles),
    do: values == roles and var["roles"] == nil

  defp role_var?(_var, _roles), do: false

  # Each input's requiredIf against the variables (SPEC §4.2.1): it names
  # another declared variable, a plain string, int, bool or enum one that is
  # not secret, and a value that variable can hold. A bool is not an int.
  defp check_conditions(%Declaration{} = decl) do
    inputs =
      Enum.map(decl.vars, &{"env #{&1.name}", &1.name, &1.required_if}) ++
        Enum.map(decl.files, &{"file #{&1.name}", &1.name, &1.required_if})

    for {label, input, {name, value}} <- inputs,
        problem = condition_problem(input, name, value, decl.vars) do
      "#{label}: #{problem}"
    end
  end

  defp condition_problem(input, name, value, vars) do
    case Enum.find(vars, &(&1.name == name)) do
      %Var{} = var when name != input -> condition_value_problem(name, value, var)
      _ -> "requiredIf must name another declared variable, not #{inspect(name)}"
    end
  end

  defp condition_value_problem(name, value, %Var{} = var) do
    same_type? =
      case var.type do
        "int" -> is_integer(value)
        "bool" -> is_boolean(value)
        _ -> is_binary(value)
      end

    shown = "#{name} is #{JSON.encode!(value)}"

    cond do
      var.secret or var.type not in ["string", "int", "bool", "enum"] ->
        "requiredIf names #{name}, which is not a plain string, int, bool or enum variable"

      not same_type? ->
        "requiredIf: #{shown} is not a value #{name} can have"

      true ->
        case Value.check(var, value) do
          {:ok, _} -> nil
          {:error, _code, msg} -> "requiredIf: #{shown} is not a value #{name} can have: #{msg}"
        end
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
