defmodule Docuconf.TOML do
  @moduledoc """
  A TOML 1.0 reader with no dependencies, for `toml` config files and
  overlays in contract-first mode (`Docuconf.Contract`), and for a
  `config_file` declaration that wants it (`decoder: &Docuconf.TOML.decode/1`).

  It reads the whole of TOML 1.0: tables, arrays of tables, dotted and
  quoted keys, inline tables, every string, integer and float form, and
  booleans. Dates and times come back as their RFC 3339 text, the way a
  JSON Schema sees them. A redefined key or table is an error, as the
  specification requires.

      iex> Docuconf.TOML.decode(~s(name = "orders"\\n[limits]\\nburst = 10\\n))
      {:ok, %{"name" => "orders", "limits" => %{"burst" => 10}}}
  """

  @doc "Decodes a TOML document into maps, lists and scalars."
  @spec decode(String.t()) :: {:ok, map()} | {:error, String.t()}
  def decode(text) when is_binary(text) do
    if String.valid?(text) do
      try do
        {:ok, document(text)}
      catch
        {:toml_error, line, msg} -> {:error, "line #{line}: #{msg}"}
      end
    else
      {:error, "not valid UTF-8"}
    end
  end

  # State: the root map, the path of the current table, the paths of tables
  # defined with a header (or implicitly by dotted keys, which may not be
  # reopened as a header), inline tables (closed), and arrays of tables.
  defp document(text) do
    st = %{
      root: %{},
      table: [],
      defined: MapSet.new(),
      dotted: MapSet.new(),
      frozen: MapSet.new(),
      aot: MapSet.new()
    }

    st = statements(text, 1, st)
    st.root
  end

  defp statements(s, line, st) do
    {s, line} = skip_blank(s, line)

    case s do
      "" ->
        st

      "[[" <> rest ->
        {key, rest} = key(skip_ws(rest), line)
        rest = expect(skip_ws(rest), "]]", line)
        st = array_table(st, key, line)
        statements(end_of_line(rest, line), line + 1, st)

      "[" <> rest ->
        {key, rest} = key(skip_ws(rest), line)
        rest = expect(skip_ws(rest), "]", line)
        st = table(st, key, line)
        statements(end_of_line(rest, line), line + 1, st)

      _ ->
        {key, rest} = key(s, line)
        rest = expect(skip_ws(rest), "=", line)
        {value, rest, line2} = value(skip_ws(rest), line)
        st = assign(st, st.table ++ key, value, line)
        statements(end_of_line(rest, line2), line2 + 1, st)
    end
  end

  defp fail(line, msg), do: throw({:toml_error, line, msg})

  defp skip_ws(<<c, rest::binary>>) when c in [?\s, ?\t], do: skip_ws(rest)
  defp skip_ws(s), do: s

  # Blank lines and comment lines.
  defp skip_blank(s, line) do
    s = skip_ws(s)

    case s do
      "\r\n" <> rest -> skip_blank(rest, line + 1)
      "\n" <> rest -> skip_blank(rest, line + 1)
      "#" <> _ -> s |> comment(line) |> skip_blank(line)
      _ -> {s, line}
    end
  end

  # A comment, up to (not including) the newline.
  defp comment("#" <> rest, line), do: comment_body(rest, line)

  defp comment_body(<<"\n", _::binary>> = s, _line), do: s
  defp comment_body(<<"\r\n", _::binary>> = s, _line), do: s
  defp comment_body("", _line), do: ""

  defp comment_body(<<c::utf8, rest::binary>>, line) do
    if (c < 0x20 and c != ?\t) or c == 0x7F, do: fail(line, "control character in a comment")
    comment_body(rest, line)
  end

  defp end_of_line(s, line) do
    s = skip_ws(s)

    case s do
      "" -> ""
      "\n" <> rest -> rest
      "\r\n" <> rest -> rest
      "#" <> _ -> s |> comment(line) |> end_of_line(line)
      _ -> fail(line, "expected the end of the line, found #{inspect(String.slice(s, 0, 10))}")
    end
  end

  defp expect(s, token, line) do
    if String.starts_with?(s, token),
      do: binary_part(s, byte_size(token), byte_size(s) - byte_size(token)),
      else: fail(line, "expected #{inspect(token)}")
  end

  # ---- keys -----------------------------------------------------------------

  defp key(s, line) do
    {part, rest} = simple_key(s, line)
    rest1 = skip_ws(rest)

    case rest1 do
      "." <> more ->
        {parts, rest2} = key(skip_ws(more), line)
        {[part | parts], rest2}

      _ ->
        {[part], rest}
    end
  end

  defp simple_key("\"" <> _ = s, line) do
    if String.starts_with?(s, ~s(""")), do: fail(line, "a key cannot be a multi-line string")
    basic_string(binary_part(s, 1, byte_size(s) - 1), line, "")
  end

  defp simple_key("'" <> _ = s, line) do
    if String.starts_with?(s, "'''"), do: fail(line, "a key cannot be a multi-line string")
    literal_string(binary_part(s, 1, byte_size(s) - 1), line, "")
  end

  defp simple_key(s, line) do
    case Regex.run(~r/\A[A-Za-z0-9_-]+/, s) do
      [k] -> {k, binary_part(s, byte_size(k), byte_size(s) - byte_size(k))}
      nil -> fail(line, "expected a key")
    end
  end

  # ---- tables ---------------------------------------------------------------

  defp table(st, path, line) do
    if MapSet.member?(st.defined, path) or MapSet.member?(st.aot, path) or
         MapSet.member?(st.frozen, path) or MapSet.member?(st.dotted, path),
       do: fail(line, "table [#{Enum.join(path, ".")}] is defined more than once")

    root = ensure_table(st.root, path, st, line, [])
    %{st | root: root, table: path, defined: MapSet.put(st.defined, path)}
  end

  defp array_table(st, path, line) do
    {parent, [last]} = Enum.split(path, -1)
    root = ensure_table(st.root, parent, st, line, [])

    root =
      update_at(root, parent, fn container ->
        case Map.get(container, last) do
          nil ->
            if MapSet.member?(st.defined, path),
              do: fail(line, "[[#{Enum.join(path, ".")}]] is a table")

            Map.put(container, last, [%{}])

          list when is_list(list) ->
            unless MapSet.member?(st.aot, path),
              do: fail(line, "#{Enum.join(path, ".")} is a static array")

            Map.put(container, last, list ++ [%{}])

          _ ->
            fail(line, "#{Enum.join(path, ".")} is already a value")
        end
      end)

    # Tables under the previous element of this array are new again.
    prefix_len = length(path)

    defined =
      st.defined
      |> Enum.reject(&(length(&1) > prefix_len and Enum.take(&1, prefix_len) == path))
      |> MapSet.new()

    aot =
      st.aot
      |> Enum.reject(&(length(&1) > prefix_len and Enum.take(&1, prefix_len) == path))
      |> MapSet.new()
      |> MapSet.put(path)

    %{st | root: root, table: path, defined: defined, aot: aot}
  end

  # Walks to `path`, creating tables, and descending into the last element
  # of an array of tables.
  defp ensure_table(map, [], _st, _line, _seen), do: map

  defp ensure_table(map, [k | rest], st, line, seen) do
    here = seen ++ [k]

    if MapSet.member?(st.frozen, here),
      do: fail(line, "#{Enum.join(here, ".")} is an inline table and cannot be extended")

    case Map.get(map, k) do
      nil ->
        Map.put(map, k, ensure_table(%{}, rest, st, line, here))

      %{} = m ->
        Map.put(map, k, ensure_table(m, rest, st, line, here))

      list when is_list(list) and list != [] ->
        unless MapSet.member?(st.aot, here),
          do: fail(line, "#{Enum.join(here, ".")} is not a table")

        {init, [lst]} = Enum.split(list, -1)
        Map.put(map, k, init ++ [ensure_table(lst, rest, st, line, here)])

      _ ->
        fail(line, "#{Enum.join(here, ".")} is already a value")
    end
  end

  # Applies fun to the table at path (descending into arrays of tables).
  defp update_at(map, [], fun), do: fun.(map)

  defp update_at(map, [k | rest], fun) do
    case Map.fetch!(map, k) do
      %{} = m ->
        Map.put(map, k, update_at(m, rest, fun))

      list when is_list(list) ->
        {init, [lst]} = Enum.split(list, -1)
        Map.put(map, k, init ++ [update_at(lst, rest, fun)])
    end
  end

  defp assign(st, path, value, line) do
    {parent, [last]} = Enum.split(path, -1)

    # Dotted keys define tables implicitly; those cannot be reopened with a
    # [header] later, and may not extend a table defined elsewhere.
    implicit = for n <- (length(st.table) + 1)..(length(path) - 1)//1, do: Enum.take(path, n)

    for p <- implicit,
        MapSet.member?(st.defined, p) or MapSet.member?(st.aot, p),
        do: fail(line, "#{Enum.join(p, ".")} is defined more than once")

    root = ensure_table(st.root, parent, st, line, [])

    root =
      update_at(root, parent, fn t ->
        if Map.has_key?(t, last),
          do: fail(line, "#{Enum.join(path, ".")} is defined more than once")

        Map.put(t, last, value)
      end)

    frozen = if is_map(value), do: MapSet.put(st.frozen, path), else: st.frozen

    frozen =
      if is_map(value),
        do: Enum.reduce(inline_paths(value, path), frozen, &MapSet.put(&2, &1)),
        else: frozen

    dotted = Enum.reduce(implicit, st.dotted, &MapSet.put(&2, &1))
    %{st | root: root, frozen: frozen, dotted: dotted}
  end

  defp inline_paths(map, path) do
    for {k, v} <- map, is_map(v), p <- [path ++ [k] | inline_paths(v, path ++ [k])], do: p
  end

  # ---- values ---------------------------------------------------------------

  # Returns {value, rest, line} (line advances inside multi-line values).
  defp value(~s(""") <> rest, line), do: ml_basic(trim_first_newline(rest), line, "")
  defp value("'''" <> rest, line), do: ml_literal(trim_first_newline(rest), line, "")

  defp value("\"" <> rest, line) do
    {s, rest} = basic_string(rest, line, "")
    {s, rest, line}
  end

  defp value("'" <> rest, line) do
    {s, rest} = literal_string(rest, line, "")
    {s, rest, line}
  end

  defp value("[" <> rest, line), do: array(rest, line, [])
  defp value("{" <> rest, line), do: inline_table(rest, line)
  defp value("true" <> rest, line), do: {true, delimited(rest, line), line}
  defp value("false" <> rest, line), do: {false, delimited(rest, line), line}

  defp value(s, line) do
    case Regex.run(~r/\A[0-9A-Za-z_:.+\-]+(?: [0-9][0-9:.+\-Zz]*)?/, s) do
      [tok] ->
        rest = binary_part(s, byte_size(tok), byte_size(s) - byte_size(tok))
        {tok, rest} = split_datetime(tok, rest)
        {scalar(tok, line), rest, line}

      nil ->
        fail(line, "expected a value")
    end
  end

  defp delimited(rest, line) do
    case rest do
      <<c, _::binary>> when c in [?\s, ?\t, ?\n, ?\r, ?,, ?], ?}, ?#] -> rest
      "" -> rest
      _ -> fail(line, "invalid value")
    end
  end

  # "1979-05-27 07:32:00" is one date-time; "1979-05-27 # c" is a date and a
  # comment.
  defp split_datetime(tok, rest) do
    case String.split(tok, " ", parts: 2) do
      [d, t] ->
        if Regex.match?(~r/\A\d{4}-\d{2}-\d{2}\z/, d) and Regex.match?(~r/\A\d{2}:/, t),
          do: {tok, rest},
          else: {d, " " <> t <> rest}

      [_] ->
        {tok, rest}
    end
  end

  @date ~S"\d{4}-\d{2}-\d{2}"
  @time ~S"\d{2}:\d{2}:\d{2}(?:\.\d+)?"
  @offset ~S"(?:[Zz]|[+-]\d{2}:\d{2})"

  defp scalar(tok, line) do
    cond do
      Regex.match?(~r/\A[+-]?(?:0|[1-9](?:_?[0-9])*)\z/, tok) ->
        tok |> String.replace("_", "") |> String.to_integer()

      Regex.match?(~r/\A0x[0-9A-Fa-f](?:_?[0-9A-Fa-f])*\z/, tok) ->
        tok
        |> binary_part(2, byte_size(tok) - 2)
        |> String.replace("_", "")
        |> String.to_integer(16)

      Regex.match?(~r/\A0o[0-7](?:_?[0-7])*\z/, tok) ->
        tok
        |> binary_part(2, byte_size(tok) - 2)
        |> String.replace("_", "")
        |> String.to_integer(8)

      Regex.match?(~r/\A0b[01](?:_?[01])*\z/, tok) ->
        tok
        |> binary_part(2, byte_size(tok) - 2)
        |> String.replace("_", "")
        |> String.to_integer(2)

      Regex.match?(
        ~r/\A[+-]?(?:0|[1-9](?:_?[0-9])*)(?:\.[0-9](?:_?[0-9])*)?(?:[eE][+-]?[0-9](?:_?[0-9])*)?\z/,
        tok
      ) ->
        float(tok, line)

      Regex.match?(~r/\A[+-]?(inf|nan)\z/, tok) ->
        fail(line, "#{tok} has no JSON equivalent")

      Regex.match?(~r/\A#{@date}[Tt ]#{@time}#{@offset}?\z/, tok) or
        Regex.match?(~r/\A#{@date}\z/, tok) or Regex.match?(~r/\A#{@time}\z/, tok) ->
        datetime(tok, line)

      true ->
        fail(line, "invalid value #{inspect(tok)}")
    end
  end

  defp float(tok, line) do
    t = String.replace(tok, "_", "")
    [mant | exp] = String.split(t, ["e", "E"], parts: 2)
    mant = if String.contains?(mant, "."), do: mant, else: mant <> ".0"
    t = if exp == [], do: mant, else: mant <> "e" <> hd(exp)

    case Float.parse(t) do
      {f, ""} -> f
      _ -> fail(line, "invalid float #{inspect(tok)}")
    end
  rescue
    ArgumentError -> fail(line, "float #{inspect(tok)} is out of range")
  end

  defp datetime(tok, line) do
    valid =
      case Regex.run(~r/\A(\d{4}-\d{2}-\d{2})?[Tt ]?(\d{2}:\d{2}:\d{2}(?:\.\d+)?)?(.*)\z/, tok) do
        [_ | parts] ->
          [d, t | _] = parts ++ ["", ""]

          (d == "" or match?({:ok, _}, Date.from_iso8601(d))) and
            (t == "" or match?({:ok, _}, Time.from_iso8601(t)))

        nil ->
          false
      end

    if valid,
      do: String.replace(tok, " ", "T"),
      else: fail(line, "invalid date or time #{inspect(tok)}")
  end

  defp array(s, line, acc) do
    {s, line} = skip_blank(s, line)

    case s do
      "]" <> rest ->
        {Enum.reverse(acc), rest, line}

      _ ->
        {v, rest, line} = value(s, line)
        {rest, line} = skip_blank(rest, line)

        case rest do
          "," <> more -> array(more, line, [v | acc])
          "]" <> more -> {Enum.reverse([v | acc]), more, line}
          _ -> fail(line, "expected , or ] in an array")
        end
    end
  end

  defp inline_table(s, line) do
    s = skip_ws(s)

    case s do
      "}" <> rest ->
        {%{}, rest, line}

      _ ->
        st = %{
          root: %{},
          table: [],
          defined: MapSet.new(),
          dotted: MapSet.new(),
          frozen: MapSet.new(),
          aot: MapSet.new()
        }

        inline_pairs(s, line, st)
    end
  end

  defp inline_pairs(s, line, st) do
    {key, rest} = key(skip_ws(s), line)
    rest = expect(skip_ws(rest), "=", line)
    {v, rest, line} = value(skip_ws(rest), line)
    st = assign(st, key, v, line)
    rest = skip_ws(rest)

    case rest do
      "," <> more -> inline_pairs(more, line, st)
      "}" <> more -> {st.root, more, line}
      _ -> fail(line, "expected , or } in an inline table (inline tables are one line)")
    end
  end

  # ---- strings --------------------------------------------------------------

  defp trim_first_newline("\r\n" <> rest), do: rest
  defp trim_first_newline("\n" <> rest), do: rest
  defp trim_first_newline(rest), do: rest

  defp basic_string("\"" <> rest, _line, acc), do: {acc, rest}

  defp basic_string("\\" <> rest, line, acc) do
    {c, rest} = escape(rest, line)
    basic_string(rest, line, acc <> c)
  end

  defp basic_string(<<c::utf8, rest::binary>>, line, acc) do
    if c == ?\n or (c < 0x20 and c != ?\t) or c == 0x7F,
      do: fail(line, "unterminated or invalid string")

    basic_string(rest, line, acc <> <<c::utf8>>)
  end

  defp basic_string("", line, _acc), do: fail(line, "unterminated string")

  defp literal_string("'" <> rest, _line, acc), do: {acc, rest}

  defp literal_string(<<c::utf8, rest::binary>>, line, acc) do
    if c == ?\n or (c < 0x20 and c != ?\t) or c == 0x7F,
      do: fail(line, "unterminated or invalid string")

    literal_string(rest, line, acc <> <<c::utf8>>)
  end

  defp literal_string("", line, _acc), do: fail(line, "unterminated string")

  # Up to two quotes may end the content just before the closing delimiter.
  defp ml_basic(~s(""""") <> rest, line, acc), do: {acc <> ~s(""), rest, line}
  defp ml_basic(~s("""") <> rest, line, acc), do: {acc <> ~s("), rest, line}
  defp ml_basic(~s(""") <> rest, line, acc), do: {acc, rest, line}

  defp ml_basic("\\" <> rest, line, acc) do
    case Regex.run(~r/\A[ \t]*\r?\n/, rest) do
      [_] ->
        {rest, line} = skip_ml_ws(rest, line)
        ml_basic(rest, line, acc)

      nil ->
        {c, rest} = escape(rest, line)
        ml_basic(rest, line, acc <> c)
    end
  end

  defp ml_basic("\r\n" <> rest, line, acc), do: ml_basic(rest, line + 1, acc <> "\n")
  defp ml_basic("\n" <> rest, line, acc), do: ml_basic(rest, line + 1, acc <> "\n")

  defp ml_basic(<<c::utf8, rest::binary>>, line, acc) do
    if (c < 0x20 and c != ?\t) or c == 0x7F, do: fail(line, "control character in a string")
    ml_basic(rest, line, acc <> <<c::utf8>>)
  end

  defp ml_basic("", line, _acc), do: fail(line, "unterminated multi-line string")

  defp skip_ml_ws(<<c, rest::binary>>, line) when c in [?\s, ?\t], do: skip_ml_ws(rest, line)
  defp skip_ml_ws("\r\n" <> rest, line), do: skip_ml_ws(rest, line + 1)
  defp skip_ml_ws("\n" <> rest, line), do: skip_ml_ws(rest, line + 1)
  defp skip_ml_ws(rest, line), do: {rest, line}

  defp ml_literal("'''''" <> rest, line, acc), do: {acc <> "''", rest, line}
  defp ml_literal("''''" <> rest, line, acc), do: {acc <> "'", rest, line}
  defp ml_literal("'''" <> rest, line, acc), do: {acc, rest, line}
  defp ml_literal("\r\n" <> rest, line, acc), do: ml_literal(rest, line + 1, acc <> "\n")
  defp ml_literal("\n" <> rest, line, acc), do: ml_literal(rest, line + 1, acc <> "\n")

  defp ml_literal(<<c::utf8, rest::binary>>, line, acc) do
    if (c < 0x20 and c != ?\t) or c == 0x7F, do: fail(line, "control character in a string")
    ml_literal(rest, line, acc <> <<c::utf8>>)
  end

  defp ml_literal("", line, _acc), do: fail(line, "unterminated multi-line string")

  defp escape(<<c, rest::binary>>, _line) when c in ~c'btnfr"\\' do
    {%{?b => "\b", ?t => "\t", ?n => "\n", ?f => "\f", ?r => "\r", ?" => "\"", ?\\ => "\\"}[c],
     rest}
  end

  defp escape("u" <> <<hex::binary-size(4), rest::binary>>, line),
    do: {codepoint(hex, line), rest}

  defp escape("U" <> <<hex::binary-size(8), rest::binary>>, line),
    do: {codepoint(hex, line), rest}

  defp escape(_, line), do: fail(line, "invalid escape in a string")

  defp codepoint(hex, line) do
    with true <- Regex.match?(~r/\A[0-9A-Fa-f]+\z/, hex),
         n = String.to_integer(hex, 16),
         true <- n <= 0x10FFFF and n not in 0xD800..0xDFFF do
      <<n::utf8>>
    else
      _ -> fail(line, "invalid unicode escape")
    end
  end
end
