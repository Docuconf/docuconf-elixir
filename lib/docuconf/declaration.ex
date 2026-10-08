defmodule Docuconf.Var do
  @moduledoc "A declared environment variable (SPEC §4.2), normalised."
  @type t :: %__MODULE__{}
  defstruct [
    :field,
    :name,
    :type,
    :description,
    :details,
    :group,
    :examples,
    :deprecated,
    :config_key,
    :min,
    :max,
    :min_length,
    :max_length,
    :pattern,
    :values,
    :schemes,
    :items,
    :min_items,
    :max_items,
    :item_min,
    :item_max,
    :item_min_length,
    :item_max_length,
    :encoding,
    :schema,
    :spec,
    :default,
    :line,
    required: false,
    atom_values: false,
    origin: :dsl,
    secret: false,
    has_default: false,
    separator: ",",
    unit: :millisecond,
    flag_warning: true
  ]

  @doc false
  # Option names in messages: the DSL's own (`min_length`) for a `use
  # Docuconf` declaration, the contract's (`minLength`) in contract-first mode.
  def opt_name(%{origin: :contract}, _dsl, spec), do: spec
  def opt_name(_input, dsl, _spec), do: dsl
end

defmodule Docuconf.FileInput do
  @moduledoc "A declared file input (SPEC §4.6), normalised."
  @type t :: %__MODULE__{}
  defstruct [
    :field,
    :name,
    :type,
    :description,
    :details,
    :path,
    :path_env,
    :max_size,
    :group,
    :deprecated,
    :format,
    :schema,
    :spec,
    :decoder,
    :dns_names,
    :key_algorithms,
    :min_remaining,
    :password_var,
    :pattern,
    :min_length,
    :max_length,
    :line,
    required: false,
    secret: false,
    origin: :dsl,
    reload: "restart",
    require_ca: false,
    min_certificates: 1
  ]

  @doc false
  # Does the loaded value carry the secret itself? A secret config or text
  # file's data is its content. TLS and keystore inputs are secret because
  # of their keys, but the loaded value holds only paths and certificates.
  def secret_data?(%{secret: true, type: t}) when t in ["config", "text"], do: true
  def secret_data?(_), do: false
end

defmodule Docuconf.Declaration do
  @moduledoc """
  A service's whole declaration: its variables and file inputs, built from
  the `use Docuconf` DSL and checked at compile time (SPEC §11.2 item 2).
  """

  alias Docuconf.{Duration, FileInput, JSONSchema, RE2, Value, Var}

  @type t :: %__MODULE__{
          name: String.t(),
          app_version: String.t() | nil,
          vars: [Var.t()],
          files: [FileInput.t()],
          warnings: [{pos_integer() | nil, String.t()}]
        }
  defstruct [:name, :app_version, vars: [], files: [], warnings: []]

  @common_var_opts [
    :description,
    :doc,
    :details,
    :required,
    :default,
    :secret,
    :group,
    :examples,
    :deprecated,
    :config_key,
    :name,
    :flag_warning
  ]
  @type_opts %{
    "string" => [:min_length, :max_length, :pattern],
    "int" => [:min, :max],
    "float" => [:min, :max],
    "bool" => [],
    "duration" => [:min, :max, :unit, :encoding],
    "url" => [:schemes, :max_length],
    "enum" => [:values],
    "list" => [
      :separator,
      :min_items,
      :max_items,
      :item_min,
      :item_max,
      :item_min_length,
      :item_max_length,
      :encoding
    ],
    "json" => [:schema, :max_length]
  }

  @common_file_opts [
    :description,
    :doc,
    :details,
    :required,
    :secret,
    :path,
    :path_env,
    :reload,
    :max_size,
    :group,
    :deprecated,
    :name
  ]
  @file_type_opts %{
    "config" => [:format, :schema, :decoder],
    "tls" => [:dns_names, :key_algorithms, :min_remaining, :require_ca],
    "caBundle" => [:min_certificates],
    "keystore" => [:format, :password_var],
    "text" => [:pattern, :min_length, :max_length],
    "binary" => []
  }

  @reserved_dirs ~w(/ /app /bin /boot /dev /etc /etc/pki /etc/ssl /etc/ssl/certs /home /lib /lib64
                    /opt /proc /root /run /sbin /srv /sys /tmp /usr /usr/lib /usr/local /usr/share
                    /var /var/lib /var/run)

  @doc """
  Builds and checks a declaration. `vars` are `{field, type, opts}` (or
  `{field, type, opts, line}`) and `files` `{field, file_type, opts}` (or
  with a line) in declaration order. Returns `{:ok, declaration}` or
  `{:error, problems}`.
  """
  @spec build(keyword(), [tuple()], [tuple()]) :: {:ok, t()} | {:error, [String.t()]}
  def build(opts, vars, files) do
    case build_located(opts, vars, files) do
      {:ok, decl} -> {:ok, decl}
      {:error, problems} -> {:error, Enum.map(problems, &elem(&1, 1))}
    end
  end

  @doc false
  # Like build/3, but each problem is `{line | nil, message}`, and each
  # warning in the declaration is `{line | nil, message}` too, so the
  # compiler can point at the declaration that caused it.
  def build_located(opts, vars, files) do
    origin = Keyword.get(opts, :origin, :dsl)

    {var_structs, var_problems} =
      vars |> Enum.map(&located(&1, fn d -> build_var(d, origin) end)) |> collect()

    {file_structs, file_problems} =
      files
      |> Enum.map(&located(&1, fn d -> build_file(d, var_structs, origin) end))
      |> collect()

    name = opts[:name]

    name_problems =
      cond do
        not is_binary(name) ->
          ["use Docuconf needs name: \"my-service\" (a DNS label)"]

        not Regex.match?(~r/^[a-z0-9]([-a-z0-9]{0,61}[a-z0-9])?\z/, name) ->
          ["name #{inspect(name)} must be a DNS label ([a-z0-9-], at most 63 characters)"]

        true ->
          []
      end

    problems =
      Enum.map(name_problems, &{nil, &1}) ++
        var_problems ++
        file_problems ++ Enum.map(cross_checks(var_structs, file_structs), &{nil, &1})

    if problems == [] do
      warnings =
        for %Var{flag_warning: true, name: n, line: line} <- var_structs,
            Regex.match?(~r/^(FF|FEATURE|FEATURE_FLAG|ENABLE)_/, n) do
          {line,
           "#{n} looks like a feature flag. Flags that change without a rollout belong in a flag service " <>
             "(OpenFeature), not the environment (SPEC §10). Pass flag_warning: false on this declaration " <>
             "if it is a deploy-time switch."}
        end

      {:ok,
       %__MODULE__{
         name: name,
         app_version: opts[:app_version],
         vars: Enum.sort_by(var_structs, & &1.name),
         files: Enum.sort_by(file_structs, & &1.name),
         warnings: warnings
       }}
    else
      {:error, problems}
    end
  end

  defp located({field, type, opts}, fun), do: located({field, type, opts, nil}, fun)

  defp located({field, type, opts, line}, fun) do
    case fun.({field, type, opts}) do
      {:ok, s} -> {:ok, %{s | line: line}}
      {:error, ps} -> {:error, Enum.map(ps, &{line, &1})}
    end
  end

  defp collect(results) do
    Enum.reduce(results, {[], []}, fn
      {:ok, s}, {ok, probs} -> {ok ++ [s], probs}
      {:error, ps}, {ok, probs} -> {ok, probs ++ ps}
    end)
  end

  # ---- variables -----------------------------------------------------------

  @type_names ~w(string integer float boolean duration url json pos_integer non_neg_integer)a

  defp normalize_type(:string), do: {"string", %{}}
  defp normalize_type(t) when t in [:integer, :int], do: {"int", %{}}
  # NimbleOptions names, as sugar for a lower bound.
  defp normalize_type(:pos_integer), do: {"int", %{min: 1}}
  defp normalize_type(:non_neg_integer), do: {"int", %{min: 0}}
  defp normalize_type(:float), do: {"float", %{}}
  defp normalize_type(t) when t in [:boolean, :bool], do: {"bool", %{}}
  defp normalize_type(:duration), do: {"duration", %{}}
  defp normalize_type(:url), do: {"url", %{}}
  defp normalize_type(:enum), do: {"enum", %{}}
  defp normalize_type({:in, values}), do: {"enum", %{values: values}}
  defp normalize_type(:json), do: {"json", %{}}
  defp normalize_type({:list, t}) when t in [:string], do: {"list", %{items: "string"}}
  defp normalize_type({:list, t}) when t in [:integer, :int], do: {"list", %{items: "int"}}
  defp normalize_type(_), do: :error

  @bool_opts [:required, :secret, :flag_warning]

  defp build_var({field, type, opts}, origin) do
    label = "env #{inspect(field)}"

    with {:opts, true} <- {:opts, is_list(opts) and Keyword.keyword?(opts)},
         {:type, {t, implied}} <- {:type, normalize_type(type)},
         {:unknown, []} <- {:unknown, Keyword.keys(opts) -- (@common_var_opts ++ @type_opts[t])} do
      opts = Keyword.merge(Enum.to_list(implied), opts)
      name = Keyword.get_lazy(opts, :name, fn -> field |> Atom.to_string() |> String.upcase() end)
      description = opts[:description] || opts[:doc]
      values = opts[:values]

      var = %Var{
        field: field,
        name: name,
        type: t,
        origin: origin,
        description: description,
        details: opts[:details],
        required: opts[:required] == true,
        secret: opts[:secret] == true,
        group: opts[:group],
        examples: opts[:examples],
        deprecated: deprecated(opts[:deprecated]),
        config_key: opts[:config_key],
        min_length: opts[:min_length],
        max_length: opts[:max_length],
        pattern: pattern_source(opts[:pattern]),
        values: if(is_list(values), do: Enum.map(values, &to_string/1)),
        atom_values: is_list(values) and values != [] and Enum.all?(values, &is_atom/1),
        schemes: opts[:schemes] && Enum.map(opts[:schemes], &to_string/1),
        items: opts[:items],
        separator: Keyword.get(opts, :separator, ","),
        min_items: opts[:min_items],
        max_items: opts[:max_items],
        item_min: opts[:item_min],
        item_max: opts[:item_max],
        item_min_length: opts[:item_min_length],
        item_max_length: opts[:item_max_length],
        encoding: opts[:encoding] && to_string(opts[:encoding]),
        unit: Keyword.get(opts, :unit, :millisecond),
        flag_warning: Keyword.get(opts, :flag_warning, true)
      }

      {var, problems} = var_specifics(var, opts)

      bool_problems =
        for k <- @bool_opts, Keyword.has_key?(opts, k), not is_boolean(opts[k]) do
          "#{k} must be true or false, got #{inspect(opts[k])}"
        end

      problems =
        problems ++
          bool_problems ++ common_var_problems(var, opts) ++ Docuconf.Docs.problems(var.details)

      label = "#{label} (#{name})"

      if problems == [],
        do: {:ok, var},
        else: {:error, Enum.map(problems, &"#{label}: #{&1}")}
    else
      {:opts, false} ->
        {:error, ["#{label}: options must be a keyword list, got #{inspect(opts)}"]}

      {:type, :error} ->
        {:error,
         [
           "#{label}: unknown type #{inspect(type)}#{suggest(type, @type_names)}; use :string, :integer, " <>
             ":pos_integer, :non_neg_integer, :float, :boolean, :duration, :url, {:in, values}, " <>
             "{:list, :string | :integer} or :json"
         ]}

      {:unknown, bad} ->
        {t, _} = normalize_type(type)
        valid = @common_var_opts ++ @type_opts[t]
        {:error, Enum.map(bad, &unknown_option(label, &1, type, valid))}
    end
  end

  defp unknown_option(label, opt, type, valid) do
    others =
      @type_opts |> Map.values() |> List.flatten() |> Enum.uniq() |> Kernel.--(valid)

    hint =
      cond do
        (s = suggestion(opt, valid)) != nil -> "; did you mean #{inspect(s)}?"
        opt in others -> "; #{inspect(opt)} does not apply to type #{inspect(type)}"
        true -> ""
      end

    "#{label}: unknown option #{inspect(opt)} for #{inspect(type)}#{hint} " <>
      "(valid: #{valid |> Enum.sort() |> Enum.map_join(", ", &Atom.to_string/1)})"
  end

  # Elixir's own "did you mean" uses String.jaro_distance/2 the same way.
  defp suggestion(given, candidates) when is_atom(given) do
    given = Atom.to_string(given)

    candidates
    |> Enum.map(&{&1, String.jaro_distance(given, Atom.to_string(&1))})
    |> Enum.filter(fn {_, d} -> d >= 0.8 end)
    |> Enum.max_by(fn {_, d} -> d end, fn -> nil end)
    |> case do
      {c, _} -> c
      nil -> nil
    end
  end

  defp suggestion(_given, _candidates), do: nil

  defp suggest(given, candidates) do
    case suggestion(given, candidates) do
      nil -> ""
      s -> " (did you mean #{inspect(s)}?)"
    end
  end

  defp pattern_source(nil), do: nil
  defp pattern_source(%Regex{source: s}), do: s
  defp pattern_source(s) when is_binary(s), do: s

  defp deprecated(nil), do: nil
  defp deprecated(msg) when is_binary(msg), do: %{message: msg}

  defp deprecated(opts) when is_list(opts),
    do: %{message: opts[:message], replaced_by: opts[:replaced_by]}

  defp var_specifics(%Var{type: "duration"} = var, opts) do
    unit_ok = var.unit in Duration.units()
    unit = if unit_ok, do: var.unit
    {min, p1} = dur(opts[:min], "min", unit, var.encoding)
    {max, p2} = dur(opts[:max], "max", unit, var.encoding)

    {default, p3} =
      if Keyword.has_key?(opts, :default),
        do: dur(opts[:default], "default", unit, var.encoding),
        else: {nil, []}

    unit_p = if unit_ok, do: [], else: ["unit must be one of #{inspect(Duration.units())}"]

    {%{var | min: min, max: max, default: default, has_default: Keyword.has_key?(opts, :default)},
     p1 ++ p2 ++ p3 ++ unit_p}
  end

  defp var_specifics(%Var{type: "json"} = var, opts) do
    var = default_from(var, opts)

    case opts[:schema] do
      nil ->
        {var, []}

      s ->
        case JSONSchema.from(s) do
          {:ok, schema} -> {%{var | schema: schema, spec: if(is_list(s), do: s)}, []}
          {:error, msg} -> {var, ["schema: #{msg}"]}
        end
    end
  end

  defp var_specifics(var, opts) do
    {%{default_from(var, opts) | min: opts[:min], max: opts[:max]}, []}
  end

  defp default_from(var, opts) do
    case Keyword.fetch(opts, :default) do
      {:ok, d} when var.type == "enum" and is_atom(d) ->
        %{var | default: Atom.to_string(d), has_default: true}

      {:ok, d} ->
        %{var | default: d, has_default: true}

      :error ->
        var
    end
  end

  # A duration given in the declaration (default, min, max, min_remaining):
  # Go syntax ("30s"), the variable's own wire encoding ("PT30S" for
  # :iso8601), an integer in the variable's unit (30_000, :timer.seconds(30)),
  # or an Elixir Duration. Returns nanoseconds.
  defp dur(value, what, unit \\ nil, encoding \\ nil)

  defp dur(nil, _what, _unit, _encoding), do: {nil, []}

  defp dur(s, what, _unit, encoding) when is_binary(s) do
    case Duration.parse(s) do
      {:ok, ns} ->
        {ns, []}

      :error ->
        case encoding not in [nil, "go"] && Duration.parse(s, encoding) do
          {:ok, ns} -> {ns, []}
          _ -> {nil, ["#{what} #{inspect(s)} is not a Go duration such as \"30s\" or \"1m30s\""]}
        end
    end
  end

  defp dur(i, what, unit, _encoding) when is_integer(i) do
    case unit && Duration.from_unit(i, unit) do
      {:ok, ns} ->
        {ns, []}

      _ ->
        {nil,
         [
           "#{what} #{i} has no unit here; write a string such as \"30s\" or an Elixir Duration " <>
             "such as Duration.new!(second: 30)"
         ]}
    end
  end

  defp dur(%{__struct__: Elixir.Duration} = d, what, _unit, _encoding) do
    case Duration.from_elixir(d) do
      {:ok, ns} -> {ns, []}
      :error -> {nil, ["#{what} #{inspect(d)} uses years or months, which have no fixed length"]}
    end
  end

  defp dur(other, what, _unit, _encoding),
    do:
      {nil,
       [
         "#{what} must be a duration such as \"30s\", an integer in the variable's unit, or an " <>
           "Elixir Duration, got #{inspect(other)}"
       ]}

  defp common_var_problems(%Var{} = v, opts) do
    [
      {not Regex.match?(~r/^[A-Z][A-Z0-9_]*\z/, v.name), "name must match ^[A-Z][A-Z0-9_]*$"},
      {not (is_binary(v.description) and String.length(v.description) >= 5),
       "description is required and must be at least 5 characters"},
      {v.required and v.has_default, "a required variable must not have a default"},
      {v.secret and v.has_default, "a secret must not have a default"},
      {v.secret and v.examples != nil, "a secret must not have examples"},
      {v.examples != nil and not (is_list(v.examples) and Enum.all?(v.examples, &is_binary/1)),
       "examples must be a list of strings"},
      {v.type == "enum" and (not is_list(v.values) or v.values == []),
       "an enum needs a non-empty values list"},
      {v.type == "list" and not (is_binary(v.separator) and v.separator != ""),
       "separator must be a non-empty string"},
      {v.type in ["int", "float", "duration"] and v.min != nil and v.max != nil and v.min > v.max,
       "min is greater than max"},
      {v.type in ["int"] and
         ((v.min != nil and not is_integer(v.min)) or (v.max != nil and not is_integer(v.max))),
       "min and max must be integers"},
      {v.type in ["float"] and
         ((v.min != nil and not is_number(v.min)) or (v.max != nil and not is_number(v.max))),
       "min and max must be numbers"},
      {v.min_length != nil and v.max_length != nil and v.min_length > v.max_length,
       "#{Var.opt_name(v, "min_length", "minLength")} is greater than #{Var.opt_name(v, "max_length", "maxLength")}"},
      {v.min_items != nil and v.max_items != nil and v.min_items > v.max_items,
       "#{Var.opt_name(v, "min_items", "minItems")} is greater than #{Var.opt_name(v, "max_items", "maxItems")}"},
      {v.type == "list" and v.encoding not in [nil, "csv", "json", "indexed"],
       "encoding must be :csv, :json or :indexed"},
      {v.type == "list" and v.encoding not in [nil, "csv"] and Keyword.has_key?(opts, :separator),
       "separator applies only to the csv encoding"},
      {v.type == "duration" and v.encoding != nil and v.encoding not in Duration.encodings(),
       "encoding must be :go, :iso8601, :seconds or :timespan"},
      {v.type == "list" and v.items != "int" and (v.item_min != nil or v.item_max != nil),
       "item_min and item_max apply only to {:list, :integer}"},
      {(v.item_min != nil and not is_integer(v.item_min)) or
         (v.item_max != nil and not is_integer(v.item_max)),
       "item_min and item_max must be integers"},
      {is_integer(v.item_min) and is_integer(v.item_max) and v.item_min > v.item_max,
       "item_min is greater than item_max"},
      {v.type == "list" and v.items != "string" and
         (v.item_min_length != nil or v.item_max_length != nil),
       "#{item_lengths(v)} apply only to {:list, :string}"},
      {Enum.any?(
         [v.max_length, v.item_min_length, v.item_max_length],
         &(&1 != nil and not (is_integer(&1) and &1 >= 0))
       ), "lengths must be non-negative integers"},
      {is_integer(v.item_min_length) and is_integer(v.item_max_length) and
         v.item_min_length > v.item_max_length,
       "#{Var.opt_name(v, "item_min_length", "itemMinLength")} is greater than #{Var.opt_name(v, "item_max_length", "itemMaxLength")}"},
      {v.schemes != nil and v.schemes == [], "schemes must not be empty"}
    ]
    |> Enum.flat_map(fn {bad, msg} -> if bad, do: [msg], else: [] end)
    |> Kernel.++(pattern_problems(v.pattern))
    |> Kernel.++(default_problems(v))
  end

  defp item_lengths(v),
    do:
      "#{Var.opt_name(v, "item_min_length", "itemMinLength")} and #{Var.opt_name(v, "item_max_length", "itemMaxLength")}"

  defp pattern_problems(nil), do: []

  defp pattern_problems(p) do
    case RE2.compile(p) do
      {:ok, _} -> []
      {:error, msg} -> ["pattern #{inspect(p)} #{msg}"]
    end
  end

  defp default_problems(%Var{has_default: false}), do: []
  defp default_problems(%Var{secret: true}), do: []
  defp default_problems(%Var{type: "duration", default: nil}), do: []

  defp default_problems(%Var{} = v) do
    # The pattern must compile before it can check the default.
    if pattern_problems(v.pattern) != [] do
      []
    else
      case Value.check(v, v.default) do
        {:ok, _} ->
          []

        {:error, code, msg} ->
          ["default does not satisfy the variable's constraints (#{code}: #{msg})"]
      end
    end
  end

  # ---- files ---------------------------------------------------------------

  defp build_file({field, type, opts}, vars, origin) do
    name =
      Keyword.get_lazy(opts, :name, fn ->
        if is_atom(field), do: field |> Atom.to_string() |> String.replace("_", "-"), else: field
      end)

    field =
      if is_atom(field), do: field, else: field |> String.replace("-", "_") |> String.to_atom()

    label = "#{type} file #{inspect(name)}"

    case Keyword.keys(opts) -- (@common_file_opts ++ @file_type_opts[type]) do
      [] ->
        f = %FileInput{
          field: field,
          origin: origin,
          name: name,
          type: type,
          description: opts[:description] || opts[:doc],
          details: opts[:details],
          required: opts[:required] == true,
          secret: type in ["tls", "keystore"] or opts[:secret] == true,
          path: opts[:path],
          path_env: opts[:path_env] && to_string(opts[:path_env]),
          reload: opts[:reload] |> Kernel.||(:restart) |> to_string(),
          max_size: opts[:max_size],
          group: opts[:group],
          deprecated: deprecated(opts[:deprecated]),
          format: opts[:format] && to_string(opts[:format]),
          decoder: opts[:decoder],
          dns_names: opts[:dns_names],
          key_algorithms: opts[:key_algorithms] && Enum.map(opts[:key_algorithms], &key_alg/1),
          require_ca: opts[:require_ca] == true,
          min_certificates: Keyword.get(opts, :min_certificates, 1),
          password_var: password_var(opts[:password_var], vars),
          pattern: pattern_source(opts[:pattern]),
          min_length: opts[:min_length],
          max_length: opts[:max_length]
        }

        {f, schema_problems} = file_schema(f, opts[:schema])
        {min_remaining, dur_problems} = dur(opts[:min_remaining], "min_remaining")
        f = %{f | min_remaining: min_remaining}

        problems =
          schema_problems ++
            dur_problems ++ file_problems(f, opts) ++ Docuconf.Docs.problems(f.details)

        if problems == [], do: {:ok, f}, else: {:error, Enum.map(problems, &"#{label}: #{&1}")}

      bad ->
        valid = @common_file_opts ++ @file_type_opts[type]

        {:error,
         Enum.map(bad, fn opt ->
           hint =
             case suggestion(opt, valid) do
               nil -> ""
               s -> "; did you mean #{inspect(s)}?"
             end

           "#{label}: unknown option #{inspect(opt)}#{hint} " <>
             "(valid: #{valid |> Enum.sort() |> Enum.map_join(", ", &Atom.to_string/1)})"
         end)}
    end
  end

  defp key_alg(a) when a in [:rsa, "RSA"], do: "RSA"
  defp key_alg(a) when a in [:ecdsa, :ec, "ECDSA"], do: "ECDSA"
  defp key_alg(a) when a in [:ed25519, "Ed25519"], do: "Ed25519"
  defp key_alg(other), do: {:invalid, other}

  defp password_var(nil, _vars), do: nil
  defp password_var(name, _vars) when is_binary(name), do: name

  defp password_var(field, vars) when is_atom(field) do
    case Enum.find(vars, &(&1.field == field)) do
      %Var{name: n} -> n
      nil -> field |> Atom.to_string() |> String.upcase()
    end
  end

  defp file_schema(f, nil), do: {f, []}

  defp file_schema(f, s) do
    case JSONSchema.from(s) do
      {:ok, schema} -> {%{f | schema: schema, spec: if(is_list(s), do: s)}, []}
      {:error, msg} -> {f, ["schema: #{msg}"]}
    end
  end

  defp file_problems(%FileInput{} = f, opts) do
    [
      {not Regex.match?(~r/^[a-z]([-a-z0-9]{0,40}[a-z0-9])?\z/, f.name),
       "input name must be a DNS label of at most 42 characters ([a-z0-9-], starting with a letter)"},
      {not (is_binary(f.description) and String.length(f.description) >= 5),
       "description is required and must be at least 5 characters"},
      {not abs_path?(f.path),
       "path must be absolute and normalised (no ., .., // or trailing /)"},
      {f.path_env != nil and not Regex.match?(~r/^[A-Z][A-Z0-9_]*\z/, f.path_env),
       "path_env must match ^[A-Z][A-Z0-9_]*$"},
      {f.reload not in ["restart", "watch"], "reload must be :restart or :watch"},
      {f.max_size != nil and not (is_integer(f.max_size) and f.max_size > 0),
       "max_size must be a positive integer (bytes)"},
      {f.type in ["tls", "keystore"] and opts[:secret] == false,
       "#{f.type} inputs are always secret"},
      {f.type == "config" and f.format not in ["json", "yaml", "toml"],
       "format must be :json, :yaml or :toml"},
      {f.type == "config" and f.format in ["yaml", "toml"] and f.decoder == nil,
       "format #{f.format} needs decoder: (Elixir has no built-in #{f.format} parser), e.g. decoder: &YamlElixir.read_from_string/1"},
      {f.decoder != nil and not decoder?(f.decoder),
       "decoder must be a remote function capture (&Mod.fun/1) or {Mod, :fun}"},
      {f.type == "keystore" and f.format not in ["pkcs12", "jks"],
       "format must be :pkcs12 or :jks"},
      {f.type == "tls" and f.key_algorithms != nil and
         Enum.any?(f.key_algorithms, &match?({:invalid, _}, &1)),
       "key_algorithms must be :rsa, :ecdsa or :ed25519"},
      {f.type == "tls" and f.dns_names != nil and
         (f.dns_names == [] or not Enum.all?(f.dns_names, &is_binary/1)),
       "dns_names must be a non-empty list of strings"},
      {f.type == "caBundle" and not (is_integer(f.min_certificates) and f.min_certificates >= 1),
       "min_certificates must be at least 1"},
      {f.min_length != nil and f.max_length != nil and f.min_length > f.max_length,
       "min_length is greater than max_length"}
    ]
    |> Enum.flat_map(fn {bad, msg} -> if bad, do: [msg], else: [] end)
    |> Kernel.++(pattern_problems(f.pattern))
  end

  defp decoder?(fun) when is_function(fun, 1), do: Function.info(fun, :type) == {:type, :external}
  defp decoder?({m, f}) when is_atom(m) and is_atom(f), do: true
  defp decoder?(_), do: false

  defp abs_path?(p) when is_binary(p) do
    Regex.match?(~r/^\/[A-Za-z0-9._\/-]+\z/, p) and not Regex.match?(~r/(^|\/)\.\.?(\/|$)/, p) and
      not String.contains?(p, "//") and not String.ends_with?(p, "/")
  end

  defp abs_path?(_), do: false

  @doc false
  def mount_dir(%FileInput{type: "tls", path: p}), do: p
  def mount_dir(%FileInput{path: p}), do: Path.dirname(p)

  defp cross_checks(vars, files) do
    var_names = Enum.map(vars, & &1.name)
    file_names = Enum.map(files, & &1.name)

    dup = fn names, what ->
      names
      |> Enum.frequencies()
      |> Enum.filter(fn {_, n} -> n > 1 end)
      |> Enum.map(fn {k, _} -> "#{what} #{k} is declared more than once" end)
    end

    mounts =
      files
      |> Enum.filter(&abs_path?(&1.path))
      |> Enum.group_by(&mount_dir/1)
      |> Enum.flat_map(fn
        {dir, [_, _ | _] = fs} ->
          ["file inputs #{Enum.map_join(fs, ", ", & &1.name)} share mount directory #{dir}"]

        _ ->
          []
      end)

    reserved =
      for f <- files, abs_path?(f.path), mount_dir(f) in @reserved_dirs do
        "file #{inspect(f.name)} would be mounted at reserved directory #{mount_dir(f)}; use a dedicated directory"
      end

    path_envs =
      for f <- files, f.path_env != nil, f.path_env in var_names do
        "file #{inspect(f.name)}: path_env #{f.path_env} must not also be declared as a variable"
      end

    pw =
      for f <- files,
          f.type == "keystore",
          f.password_var != nil,
          not Enum.any?(vars, &(&1.name == f.password_var and &1.secret)) do
        "keystore #{inspect(f.name)}: password_var #{f.password_var} must name a declared secret variable"
      end

    dup.(var_names, "variable") ++
      dup.(file_names, "file input") ++
      dup.(Enum.map(vars, & &1.field) ++ Enum.map(files, & &1.field), "field") ++
      dup.(for(f <- files, f.path_env, do: f.path_env), "path_env") ++
      mounts ++ reserved ++ path_envs ++ pw
  end
end
