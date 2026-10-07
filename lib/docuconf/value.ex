defmodule Docuconf.Value do
  @moduledoc false
  # Parsing of wire strings (SPEC §5) and constraint checks (SPEC §4.3).
  #
  # Values move through three forms: the wire string from the environment,
  # an internal typed value (durations in nanoseconds), and the public value
  # the app sees (durations in the declared unit). Defaults are given in the
  # internal form, so the same checks validate them at declaration time.

  alias Docuconf.{Duration, JSONSchema, RE2, Var}

  @int_min -9_223_372_036_854_775_808
  @int_max 9_223_372_036_854_775_807

  @duration_forms %{
    "go" => "a Go duration such as 1m30s",
    "iso8601" => "an ISO 8601 duration such as PT1M30S",
    "seconds" => "a number of seconds such as 90",
    "timespan" => "a TimeSpan such as 00:01:30"
  }

  @doc "The wire encoding of a list or duration variable (SPEC §5)."
  def encoding(%Var{encoding: e}) when is_binary(e), do: e
  def encoding(%Var{type: "list"}), do: "csv"
  def encoding(%Var{type: "duration"}), do: "go"
  def encoding(_), do: nil

  @type result :: {:ok, term()} | {:error, Docuconf.Violation.code(), String.t()}

  @doc "Parses a non-empty wire string, then checks it."
  @spec parse(Var.t(), String.t()) :: result()
  def parse(%Var{} = var, raw) do
    with {:ok, v} <- parse_type(var, raw), do: check(var, v, raw)
  end

  defp shown(%Var{secret: true}, _raw), do: "value"
  defp shown(_var, raw), do: inspect(raw)

  defp parse_type(%Var{type: "string"}, raw) do
    if String.valid?(raw), do: {:ok, raw}, else: {:error, :invalid_type, "is not valid UTF-8"}
  end

  defp parse_type(%Var{type: "int"} = var, raw) do
    case parse_int(raw) do
      {:ok, i} -> {:ok, i}
      :range -> {:error, :out_of_range, "#{shown(var, raw)} is outside the 64-bit integer range"}
      :error -> {:error, :invalid_type, "#{shown(var, raw)} is not an integer"}
    end
  end

  defp parse_type(%Var{type: "float"} = var, raw) do
    case parse_float(raw) do
      {:ok, f} -> {:ok, f}
      :error -> {:error, :invalid_type, "#{shown(var, raw)} is not a finite decimal number"}
    end
  end

  defp parse_type(%Var{type: "bool"} = var, raw) do
    case String.downcase(raw) do
      "true" -> {:ok, true}
      "false" -> {:ok, false}
      _ -> {:error, :invalid_type, "#{shown(var, raw)} is not true or false"}
    end
  end

  defp parse_type(%Var{type: "duration"} = var, raw) do
    encoding = encoding(var)

    case Duration.parse(raw, encoding) do
      {:ok, ns} ->
        {:ok, ns}

      :error ->
        {:error, :invalid_type,
         "#{shown(var, raw)} is not #{@duration_forms[encoding]}#{duration_hint(var, raw, encoding)}"}
    end
  end

  defp parse_type(%Var{type: "url"} = var, raw) do
    if String.valid?(raw) and Regex.match?(~r/^[a-zA-Z][a-zA-Z0-9+.-]*:\/\/[^\s]+\z/, raw),
      do: {:ok, raw},
      else: {:error, :invalid_type, "#{shown(var, raw)} is not a URL with a scheme://"}
  end

  defp parse_type(%Var{type: "enum"}, raw), do: {:ok, raw}

  defp parse_type(%Var{type: "list"} = var, raw) do
    with {:ok, items} <- list_items(var, encoding(var), raw) do
      if var.items == "int", do: int_items(var, items), else: {:ok, items}
    end
  end

  defp parse_type(%Var{type: "json"} = var, raw) do
    case JSON.decode(raw) do
      {:ok, v} ->
        {:ok, v}

      {:error, reason} ->
        detail = if var.secret, do: "", else: " (#{json_error(reason)})"
        {:error, :invalid_type, "is not valid JSON#{detail}"}
    end
  end

  # A value written in another encoding (30s where PT30S is expected) gets
  # the same duration in the expected form. Never for a secret.
  defp duration_hint(%Var{secret: true}, _raw, _encoding), do: ""

  defp duration_hint(_var, raw, encoding) do
    case Enum.find_value(Duration.encodings() -- [encoding], &ok_ns(Duration.parse(raw, &1))) do
      nil -> ""
      ns -> "; write #{Duration.format(ns, encoding)}"
    end
  end

  defp ok_ns({:ok, ns}), do: ns
  defp ok_ns(_), do: nil

  # csv and indexed items are strings; json items are already typed.
  defp list_items(var, "csv", raw), do: {:ok, String.split(raw, var.separator)}
  defp list_items(_var, "indexed", items) when is_list(items), do: {:ok, items}

  defp list_items(var, "json", raw) do
    item? = if var.items == "int", do: &is_integer/1, else: &is_binary/1

    case JSON.decode(raw) do
      {:ok, items} when is_list(items) ->
        case Enum.find_index(items, &(not item?.(&1))) do
          nil -> {:ok, items}
          i -> {:error, :invalid_type, "item #{i + 1} is not #{article(var.items)}"}
        end

      {:ok, _} ->
        {:error, :invalid_type, "is not a JSON array"}

      {:error, reason} ->
        detail = if var.secret, do: "", else: " (#{json_error(reason)})"
        {:error, :invalid_type, "is not a JSON array#{detail}"}
    end
  end

  defp article("int"), do: "an integer"
  defp article("string"), do: "a string"

  defp int_items(var, items) do
    items
    |> Enum.with_index(1)
    |> Enum.reduce_while({:ok, []}, fn
      {n, _i}, {:ok, acc} when is_integer(n) ->
        if n < @int_min or n > @int_max,
          do: {:halt, {:error, :out_of_range, "an item is outside the 64-bit integer range"}},
          else: {:cont, {:ok, [n | acc]}}

      {item, i}, {:ok, acc} ->
        case parse_int(item) do
          {:ok, n} ->
            {:cont, {:ok, [n | acc]}}

          :range ->
            {:halt,
             {:error, :out_of_range,
              "item #{i} (#{shown(var, item)}) is outside the 64-bit integer range"}}

          :error ->
            {:halt, {:error, :invalid_type, "item #{i} (#{shown(var, item)}) is not an integer"}}
        end
    end)
    |> case do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      err -> err
    end
  end

  @doc false
  def json_error({:unexpected_end, pos}), do: "unexpected end at byte #{pos}"
  def json_error({:invalid_byte, pos, _}), do: "invalid byte at #{pos}"
  def json_error({:unexpected_sequence, pos, _}), do: "unexpected sequence at byte #{pos}"
  def json_error(other), do: inspect(other)

  @doc false
  def parse_int(raw) do
    if Regex.match?(~r/^[+-]?[0-9]+\z/, raw) do
      i = String.to_integer(raw)
      if i < @int_min or i > @int_max, do: :range, else: {:ok, i}
    else
      :error
    end
  end

  # Locale-independent; rejects NaN, Inf and anything Float.parse would only
  # partly consume.
  defp parse_float(raw) do
    case Regex.run(~r/^([+-]?)([0-9]*)(?:\.([0-9]*))?(?:[eE]([+-]?[0-9]+))?\z/, raw) do
      [_ | groups] ->
        [sign, int, frac, exp] = groups ++ List.duplicate("", 4 - length(groups))

        if int == "" and frac == "" do
          :error
        else
          normal =
            sign <> zero(int) <> "." <> zero(frac) <> if(exp == "", do: "", else: "e" <> exp)

          try do
            {f, ""} = Float.parse(normal)
            {:ok, f}
          rescue
            _ -> :error
          end
        end

      nil ->
        :error
    end
  end

  defp zero(""), do: "0"
  defp zero(s), do: s

  @doc "Checks a typed (internal) value against the variable's constraints."
  @spec check(Var.t(), term(), String.t() | nil) :: result()
  def check(%Var{} = var, v, raw \\ nil) do
    shown = if raw == nil, do: inspect(v), else: shown(var, raw)
    shown = if var.secret, do: "value", else: shown

    with :ok <- json_length(var, v, raw),
         :ok <- constraint(var, v, shown) do
      {:ok, v}
    end
  end

  # Lengths count characters: Unicode code points, never bytes or graphemes
  # (SPEC §4.3).
  defp chars(s) when is_binary(s), do: s |> String.to_charlist() |> length()

  # maxLength on a json value bounds its wire string: the raw value as
  # received, whitespace included, or the compact JSON (no HTML escaping, as
  # the platform renders it) for a default or a config value (SPEC §4.3).
  defp json_length(%Var{type: "json", max_length: max} = var, v, raw) when is_integer(max) do
    wire = if is_binary(raw), do: raw, else: JSON.encode!(v)
    n = chars(wire)

    if n > max,
      do:
        {:error, :out_of_range,
         "is #{n} characters of JSON, longer than #{Var.opt_name(var, "max_length", "maxLength")} #{max}"},
      else: :ok
  end

  defp json_length(_var, _v, _raw), do: :ok

  defp constraint(%Var{type: "string"} = var, v, shown) do
    len = if is_binary(v) and String.valid?(v), do: chars(v), else: 0

    cond do
      not is_binary(v) ->
        {:error, :invalid_type, "#{shown} is not a string"}

      var.min_length && len < var.min_length ->
        {:error, :out_of_range,
         "#{shown} is #{len} characters, shorter than #{Var.opt_name(var, "min_length", "minLength")} #{var.min_length}"}

      var.max_length && len > var.max_length ->
        {:error, :out_of_range,
         "#{shown} is #{len} characters, longer than #{Var.opt_name(var, "max_length", "maxLength")} #{var.max_length}"}

      var.pattern && not RE2.matches?(var.pattern, v) ->
        {:error, :pattern_mismatch, "#{shown} does not match pattern #{inspect(var.pattern)}"}

      true ->
        :ok
    end
  end

  defp constraint(%Var{type: t} = var, v, shown) when t in ["int", "float"] do
    cond do
      t == "int" and not is_integer(v) ->
        {:error, :invalid_type, "#{shown} is not an integer"}

      t == "float" and not is_number(v) ->
        {:error, :invalid_type, "#{shown} is not a number"}

      var.min != nil and v < var.min ->
        {:error, :out_of_range, "#{shown} is below min #{var.min}"}

      var.max != nil and v > var.max ->
        {:error, :out_of_range, "#{shown} is above max #{var.max}"}

      true ->
        :ok
    end
  end

  defp constraint(%Var{type: "bool"}, v, shown) do
    if is_boolean(v), do: :ok, else: {:error, :invalid_type, "#{shown} is not a boolean"}
  end

  defp constraint(%Var{type: "duration"} = var, v, shown) do
    cond do
      not is_integer(v) ->
        {:error, :invalid_type, "#{shown} is not a duration"}

      var.min != nil and v < var.min ->
        {:error, :out_of_range, "#{shown} is below min #{Duration.format(var.min)}"}

      var.max != nil and v > var.max ->
        {:error, :out_of_range, "#{shown} is above max #{Duration.format(var.max)}"}

      Duration.to_unit(v, var.unit) == :error ->
        {:error, :invalid_type, "#{shown} is not a whole number of #{var.unit}s"}

      true ->
        :ok
    end
  end

  defp constraint(%Var{type: "url"} = var, v, shown) do
    scheme = v |> String.split("://", parts: 2) |> hd()

    cond do
      not is_binary(v) or not Regex.match?(~r/^[a-zA-Z][a-zA-Z0-9+.-]*:\/\/[^\s]+\z/, v) ->
        {:error, :invalid_type, "#{shown} is not a URL with a scheme://"}

      var.schemes && scheme not in var.schemes ->
        {:error, :invalid_scheme,
         "scheme #{inspect(scheme)} is not one of #{Enum.join(var.schemes, ", ")}"}

      var.max_length && chars(v) > var.max_length ->
        {:error, :out_of_range,
         "#{shown} is #{chars(v)} characters, longer than #{Var.opt_name(var, "max_length", "maxLength")} #{var.max_length}"}

      true ->
        :ok
    end
  end

  defp constraint(%Var{type: "enum"} = var, v, shown) do
    if v in var.values,
      do: :ok,
      else: {:error, :not_in_enum, "#{shown} is not one of #{Enum.join(var.values, ", ")}"}
  end

  defp constraint(%Var{type: "list"} = var, v, _shown) do
    n = if is_list(v), do: length(v), else: 0
    item_ok = if var.items == "int", do: &is_integer/1, else: &is_binary/1

    cond do
      not is_list(v) or not Enum.all?(v, item_ok) ->
        {:error, :invalid_type, "is not a list of #{var.items}"}

      var.min_items && n < var.min_items ->
        {:error, :too_few_items,
         "has #{n} items, fewer than #{Var.opt_name(var, "min_items", "minItems")} #{var.min_items}"}

      var.max_items && n > var.max_items ->
        {:error, :too_many_items,
         "has #{n} items, more than #{Var.opt_name(var, "max_items", "maxItems")} #{var.max_items}"}

      var.item_min != nil and Enum.any?(v, &(&1 < var.item_min)) ->
        i = Enum.find_index(v, &(&1 < var.item_min))

        {:error, :out_of_range,
         "item #{i + 1} is below #{Var.opt_name(var, "item_min", "itemMin")} #{var.item_min}"}

      var.item_max != nil and Enum.any?(v, &(&1 > var.item_max)) ->
        i = Enum.find_index(v, &(&1 > var.item_max))

        {:error, :out_of_range,
         "item #{i + 1} is above #{Var.opt_name(var, "item_max", "itemMax")} #{var.item_max}"}

      var.items == "string" ->
        item_lengths(var, v)

      true ->
        :ok
    end
  end

  defp constraint(%Var{type: "json"} = var, v, _shown) do
    case var.schema && JSONSchema.validate(v, var.schema) do
      problems when problems in [nil, []] ->
        :ok

      problems ->
        detail =
          if var.secret,
            do: Enum.map(problems, &(&1 |> String.split(":") |> hd())),
            else: problems

        {:error, :schema_mismatch, "does not match its schema: " <> Enum.join(detail, "; ")}
    end
  end

  # Each item after splitting, so a separator never counts. The first item
  # out of bounds is reported; a secret's item is never shown.
  defp item_lengths(var, items) do
    lo = var.item_min_length || 0
    hi = var.item_max_length

    case Enum.find_index(items, &(chars(&1) < lo or (hi != nil and chars(&1) > hi))) do
      nil ->
        :ok

      i ->
        item = Enum.at(items, i)
        n = chars(item)
        shown = if var.secret, do: "", else: " (#{inspect(item)})"

        bound =
          if n < lo,
            do: "shorter than #{Var.opt_name(var, "item_min_length", "itemMinLength")} #{lo}",
            else: "longer than #{Var.opt_name(var, "item_max_length", "itemMaxLength")} #{hi}"

        {:error, :out_of_range, "item #{i + 1}#{shown} is #{n} characters, #{bound}"}
    end
  end

  @doc "Converts an internal value to what the app sees."
  def to_public(%Var{type: "duration", unit: unit}, ns) when is_integer(ns) do
    {:ok, v} = Duration.to_unit(ns, unit)
    v
  end

  def to_public(%Var{type: "json", spec: spec}, v) when is_list(spec),
    do: JSONSchema.bind(v, spec)

  # Every value of an atom enum is an atom literal in the declaration, so
  # the atom already exists.
  def to_public(%Var{type: "enum", atom_values: true}, v) when is_binary(v),
    do: String.to_existing_atom(v)

  def to_public(_var, v), do: v
end
