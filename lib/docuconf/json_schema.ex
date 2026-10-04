defmodule Docuconf.JSONSchema do
  @moduledoc """
  JSON Schemas for `json` variables and `config` files.

  A schema can be given two ways:

    * a JSON Schema map (string or atom keys), used as is;
    * a NimbleOptions-style keyword spec describing the app's own data, from
      which docuconf generates the JSON Schema. The loaded value is then
      bound to that spec: map keys become the spec's atoms.

  Keyword spec:

      [
        routes: [
          type: {:list, {:map, [
            match: [type: :string, required: true, pattern: "^/"],
            upstream: [type: :string, required: true],
            timeout: [type: :string]
          ]}},
          required: true,
          min_items: 1
        ]
      ]

  Types: `:string`, `:integer`, `:pos_integer`, `:non_neg_integer`, `:float`
  (any number), `:boolean`, `:map` (any object), `{:map, spec}` (an object
  with exactly these keys), `{:list, type}`, `{:in, values}` and `:any`.
  Per-key options: `:required`, `:doc`, `:default`, `:pattern`, `:min`,
  `:max`, `:min_length`, `:max_length`, `:min_items`, `:max_items`.

  Validation covers the JSON Schema keywords docuconf generates and the ones
  most hand-written schemas use: `type`, `enum`, `const`, `properties`,
  `required`, `additionalProperties`, `items`, `minItems`, `maxItems`,
  `minimum`, `maximum`, `exclusiveMinimum`, `exclusiveMaximum`, `minLength`,
  `maxLength`, `pattern`, `allOf`, `anyOf`, `oneOf`, `not`. Other keywords
  are exported but not checked at boot.
  """

  alias Docuconf.RE2

  @type spec :: keyword()
  @type schema :: map()

  @key_opts [
    :type,
    :required,
    :doc,
    :default,
    :pattern,
    :min,
    :max,
    :min_length,
    :max_length,
    :min_items,
    :max_items
  ]

  @doc "Normalises a schema option: a JSON Schema map, or a keyword spec."
  @spec from(map() | spec()) :: {:ok, schema()} | {:error, String.t()}
  def from(schema) when is_map(schema), do: {:ok, stringify(schema)}

  def from(spec) when is_list(spec) do
    {:ok, object_schema(spec)}
  rescue
    e in ArgumentError -> {:error, Exception.message(e)}
  end

  def from(other), do: {:error, "schema must be a JSON Schema map or a keyword spec, got: #{inspect(other)}"}

  defp stringify(%{} = m) do
    Map.new(m, fn {k, v} -> {to_string(k), stringify(v)} end)
  end

  defp stringify(l) when is_list(l), do: Enum.map(l, &stringify/1)
  defp stringify(a) when is_atom(a) and a not in [nil, true, false], do: Atom.to_string(a)
  defp stringify(v), do: v

  defp object_schema(spec) do
    unless Keyword.keyword?(spec), do: raise(ArgumentError, "a map spec must be a keyword list")

    props =
      Map.new(spec, fn {key, opts} ->
        unless Keyword.keyword?(opts),
          do: raise(ArgumentError, "options for #{inspect(key)} must be a keyword list")

        case Keyword.keys(opts) -- @key_opts do
          [] -> :ok
          bad -> raise ArgumentError, "unknown options for #{inspect(key)}: #{inspect(bad)}"
        end

        {Atom.to_string(key), key_schema(opts)}
      end)

    required = for {k, o} <- spec, o[:required], do: Atom.to_string(k)

    %{"type" => "object", "properties" => props, "additionalProperties" => false}
    |> put_if("required", required, required != [])
  end

  defp key_schema(opts) do
    type_schema(Keyword.get(opts, :type, :any))
    |> put_if("description", opts[:doc], is_binary(opts[:doc]))
    |> put_if("default", opts[:default], Keyword.has_key?(opts, :default))
    |> put_if("pattern", source(opts[:pattern]), opts[:pattern] != nil)
    |> put_if("minimum", opts[:min], opts[:min] != nil)
    |> put_if("maximum", opts[:max], opts[:max] != nil)
    |> put_if("minLength", opts[:min_length], opts[:min_length] != nil)
    |> put_if("maxLength", opts[:max_length], opts[:max_length] != nil)
    |> put_if("minItems", opts[:min_items], opts[:min_items] != nil)
    |> put_if("maxItems", opts[:max_items], opts[:max_items] != nil)
  end

  defp source(%Regex{source: s}), do: s
  defp source(s), do: s

  defp type_schema(:string), do: %{"type" => "string"}
  defp type_schema(:integer), do: %{"type" => "integer"}
  defp type_schema(:pos_integer), do: %{"type" => "integer", "minimum" => 1}
  defp type_schema(:non_neg_integer), do: %{"type" => "integer", "minimum" => 0}
  defp type_schema(:float), do: %{"type" => "number"}
  defp type_schema(:number), do: %{"type" => "number"}
  defp type_schema(:boolean), do: %{"type" => "boolean"}
  defp type_schema(:map), do: %{"type" => "object"}
  defp type_schema({:map, spec}), do: object_schema(spec)
  defp type_schema({:list, t}), do: %{"type" => "array", "items" => type_schema(t)}
  defp type_schema({:in, values}) when is_list(values), do: %{"enum" => Enum.map(values, &stringify/1)}
  defp type_schema(:any), do: %{}
  defp type_schema(other), do: raise(ArgumentError, "unsupported spec type #{inspect(other)}")

  defp put_if(map, _k, _v, false), do: map
  defp put_if(map, k, v, true), do: Map.put(map, k, v)

  @doc """
  Binds decoded JSON to a keyword spec: object keys named in the spec become
  atoms, recursively. Values are otherwise unchanged.
  """
  @spec bind(term(), spec() | map()) :: term()
  def bind(value, schema) when is_map(schema), do: value
  def bind(value, spec) when is_list(spec), do: bind_type(value, {:map, spec})

  defp bind_type(%{} = m, {:map, spec}) do
    Map.new(m, fn {k, v} ->
      case Enum.find(spec, fn {name, _} -> Atom.to_string(name) == k end) do
        {name, opts} -> {name, bind_type(v, Keyword.get(opts, :type, :any))}
        nil -> {k, v}
      end
    end)
  end

  defp bind_type(l, {:list, t}) when is_list(l), do: Enum.map(l, &bind_type(&1, t))
  defp bind_type(v, _), do: v

  @doc """
  Validates `value` (decoded JSON) against `schema`. Returns a list of
  problems, each `"path: message"`; empty when valid.
  """
  @spec validate(term(), schema()) :: [String.t()]
  def validate(value, schema), do: check(value, schema, "$")

  defp check(_v, true, _p), do: []
  defp check(_v, false, p), do: ["#{p}: no value is allowed here"]

  defp check(v, %{} = s, p) do
    Enum.flat_map(
      [
        &check_type/3,
        &check_enum/3,
        &check_const/3,
        &check_object/3,
        &check_array/3,
        &check_number/3,
        &check_string/3,
        &check_combinators/3
      ],
      fn f -> f.(v, s, p) end
    )
  end

  defp check_type(v, %{"type" => t}, p) do
    types = List.wrap(t)
    if Enum.any?(types, &type?(v, &1)), do: [], else: ["#{p}: expected #{Enum.join(types, " or ")}, got #{kind(v)}"]
  end

  defp check_type(_, _, _), do: []

  defp type?(v, "string"), do: is_binary(v)
  defp type?(v, "integer"), do: is_integer(v) or (is_float(v) and v == Float.round(v))
  defp type?(v, "number"), do: is_number(v)
  defp type?(v, "boolean"), do: is_boolean(v)
  defp type?(v, "object"), do: is_map(v)
  defp type?(v, "array"), do: is_list(v)
  defp type?(v, "null"), do: is_nil(v)
  defp type?(_, _), do: true

  defp kind(v) when is_binary(v), do: "string"
  defp kind(v) when is_integer(v), do: "integer"
  defp kind(v) when is_float(v), do: "number"
  defp kind(v) when is_boolean(v), do: "boolean"
  defp kind(nil), do: "null"
  defp kind(v) when is_map(v), do: "object"
  defp kind(v) when is_list(v), do: "array"
  defp kind(_), do: "unknown"

  defp check_enum(v, %{"enum" => vals}, p) do
    if Enum.any?(vals, &json_equal?(&1, v)), do: [], else: ["#{p}: must be one of #{JSON.encode!(vals)}"]
  end

  defp check_enum(_, _, _), do: []

  defp check_const(v, %{"const" => c}, p) do
    if json_equal?(c, v), do: [], else: ["#{p}: must equal #{JSON.encode!(c)}"]
  end

  defp check_const(_, _, _), do: []

  defp json_equal?(a, b) when is_number(a) and is_number(b), do: a == b
  defp json_equal?(a, b), do: a === b

  defp check_object(%{} = v, s, p) do
    props = Map.get(s, "properties", %{})
    required = Map.get(s, "required", [])

    missing =
      for r <- required, not Map.has_key?(v, r), do: "#{p}: missing required property #{inspect(r)}"

    inner =
      Enum.flat_map(Enum.sort(v), fn {k, val} ->
        cond do
          Map.has_key?(props, k) ->
            check(val, props[k], "#{p}.#{k}")

          Map.get(s, "additionalProperties") == false ->
            ["#{p}: unknown property #{inspect(k)}"]

          is_map(Map.get(s, "additionalProperties")) ->
            check(val, s["additionalProperties"], "#{p}.#{k}")

          true ->
            []
        end
      end)

    missing ++ inner
  end

  defp check_object(_, _, _), do: []

  defp check_array(v, s, p) when is_list(v) do
    n = length(v)

    bounds =
      [
        {s["minItems"], &(n < &1), "has #{n} items, fewer than minItems"},
        {s["maxItems"], &(n > &1), "has #{n} items, more than maxItems"}
      ]
      |> Enum.flat_map(fn
        {nil, _, _} -> []
        {lim, bad?, msg} -> if bad?.(lim), do: ["#{p}: #{msg} #{lim}"], else: []
      end)

    items =
      case s["items"] do
        nil -> []
        is -> v |> Enum.with_index() |> Enum.flat_map(fn {x, i} -> check(x, is, "#{p}[#{i}]") end)
      end

    bounds ++ items
  end

  defp check_array(_, _, _), do: []

  defp check_number(v, s, p) when is_number(v) do
    [
      {"minimum", &(v < &1), "is below minimum"},
      {"maximum", &(v > &1), "is above maximum"},
      {"exclusiveMinimum", &(v <= &1), "must be above"},
      {"exclusiveMaximum", &(v >= &1), "must be below"}
    ]
    |> Enum.flat_map(fn {k, bad?, msg} ->
      case s[k] do
        lim when is_number(lim) -> if bad?.(lim), do: ["#{p}: #{v} #{msg} #{lim}"], else: []
        _ -> []
      end
    end)
  end

  defp check_number(_, _, _), do: []

  defp check_string(v, s, p) when is_binary(v) do
    len = if String.valid?(v), do: length(String.to_charlist(v)), else: byte_size(v)

    lens =
      [
        {s["minLength"], &(len < &1), "is shorter than minLength"},
        {s["maxLength"], &(len > &1), "is longer than maxLength"}
      ]
      |> Enum.flat_map(fn
        {nil, _, _} -> []
        {lim, bad?, msg} -> if bad?.(lim), do: ["#{p}: #{msg} #{lim}"], else: []
      end)

    pat =
      case s["pattern"] do
        nil ->
          []

        pattern ->
          case RE2.compile(pattern) do
            {:ok, re} -> if RE2.matches?(re, v), do: [], else: ["#{p}: does not match pattern #{inspect(pattern)}"]
            {:error, msg} -> ["#{p}: schema pattern #{inspect(pattern)} #{msg}"]
          end
      end

    lens ++ pat
  end

  defp check_string(_, _, _), do: []

  defp check_combinators(v, s, p) do
    all = Enum.flat_map(Map.get(s, "allOf", []), &check(v, &1, p))

    any =
      case s["anyOf"] do
        nil -> []
        subs -> if Enum.any?(subs, &(check(v, &1, p) == [])), do: [], else: ["#{p}: matches none of anyOf"]
      end

    one =
      case s["oneOf"] do
        nil ->
          []

        subs ->
          case Enum.count(subs, &(check(v, &1, p) == [])) do
            1 -> []
            n -> ["#{p}: matches #{n} of oneOf, expected exactly 1"]
          end
      end

    neg =
      case s["not"] do
        nil -> []
        sub -> if check(v, sub, p) == [], do: ["#{p}: must not match the \"not\" schema"], else: []
      end

    all ++ any ++ one ++ neg
  end
end
