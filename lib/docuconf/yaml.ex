defmodule Docuconf.YAML do
  @moduledoc """
  A YAML reader with no dependencies, for `yaml` config files and overlays
  in contract-first mode (`Docuconf.Contract`), and for a `config_file`
  declaration that wants it (`decoder: &Docuconf.YAML.decode/1`).

  It reads the YAML that configuration files are written in, with the
  YAML 1.2 core schema: block mappings and sequences, flow collections
  (`[a, b]`, `{k: v}`), plain, single- and double-quoted scalars, literal
  (`|`) and folded (`>`) block scalars, and comments. `null`, `~` and an
  empty value are null; `true` and `false` (any case: `True`, `FALSE`) are
  booleans; decimal, `0x` and `0o` integers and decimal floats are numbers;
  everything else is a string, so `yes` and `on` stay strings.

  Anything else is an error rather than a guess: anchors and aliases
  (`&a`, `*a`), tags (`!!str`), directives, several documents in one file,
  complex keys (`? `), tabs in indentation, duplicate keys, and `.inf` or
  `.nan`, which JSON cannot hold. For those, pass the decoder of a full
  YAML library (`decoder: &YamlElixir.read_from_string/1`).

      iex> Docuconf.YAML.decode("name: orders\\ntags: [a, b]\\nlimits:\\n  burst: 10\\n")
      {:ok, %{"name" => "orders", "tags" => ["a", "b"], "limits" => %{"burst" => 10}}}
  """

  # Block scalars read the raw lines (blank and #-lines are content there).
  @raw {__MODULE__, :raw}

  @doc "Decodes one YAML document into maps, lists and scalars."
  @spec decode(String.t()) :: {:ok, term()} | {:error, String.t()}
  def decode(text) when is_binary(text) do
    if String.valid?(text) do
      try do
        {:ok, document(text)}
      catch
        {:yaml_error, line, msg} -> {:error, "line #{line}: #{msg}"}
      after
        Process.delete(@raw)
      end
    else
      {:error, "not valid UTF-8"}
    end
  end

  defp fail(line, msg), do: throw({:yaml_error, line, msg})

  # Lines are {number, indent, text}; text has no trailing comment, and
  # blank or comment-only lines are kept as {n, nil, ""} for block scalars,
  # which need them.
  defp document(text) do
    lines =
      text
      |> String.replace("\r\n", "\n")
      |> String.split("\n")
      |> Enum.with_index(1)
      |> Enum.map(fn {raw, n} -> {n, raw} end)

    Process.put(@raw, Map.new(lines))
    lines = header(lines)

    case content(lines) do
      [] ->
        nil

      [{n, ind, _, _} | _] = cs ->
        if ind != 0, do: fail(n, "the document must start at column 1")
        {value, rest} = node(cs, 0)

        case rest do
          [] -> value
          [{n2, _, _, _} | _] -> fail(n2, "unexpected content (check the indentation)")
        end
    end
  end

  # Directives and document markers: one optional leading "---", an
  # optional trailing "...", nothing else.
  defp header(lines) do
    lines =
      Enum.drop_while(lines, fn {n, raw} ->
        cond do
          String.starts_with?(raw, "%") -> fail(n, "directives are not supported")
          blank?(raw) -> true
          true -> false
        end
      end)

    lines =
      case lines do
        [{_, "---"} | rest] -> rest
        [{n, "--- " <> v} | rest] -> [{n, v} | rest]
        _ -> lines
      end

    {body, tail} = Enum.split_while(lines, fn {_, raw} -> raw not in ["---", "..."] end)

    case tail do
      [] -> :ok
      [{_, "..."} | after_end] -> Enum.each(after_end, &only_blank/1)
      [{n, "---"} | _] -> fail(n, "several documents in one file are not supported")
    end

    body
  end

  defp only_blank({n, raw}),
    do: unless(blank?(raw), do: fail(n, "content after the document end"))

  defp blank?(raw) do
    t = String.trim_leading(raw, " ")
    t == "" or String.starts_with?(t, "#")
  end

  # {number, indent, text, raw} for every line with content.
  defp content(lines) do
    lines
    |> Enum.map(fn {n, raw} ->
      {indent, rest} = indentation(raw, n)
      {n, indent, rest, raw}
    end)
    |> Enum.reject(fn {_, _, rest, _} -> rest == "" or String.starts_with?(rest, "#") end)
  end

  defp indentation(raw, n) do
    rest = String.trim_leading(raw, " ")
    indent = byte_size(raw) - byte_size(rest)

    if String.starts_with?(rest, "\t") and String.trim(rest) != "",
      do: fail(n, "tabs cannot indent YAML")

    {indent, rest}
  end

  # ---- block nodes ------------------------------------------------------------

  # Parses the node whose first line is the head of `lines`, at that line's
  # indent. Returns {value, remaining lines}.
  defp node([{n, ind, text, _} | _] = lines, _min) do
    cond do
      seq_item?(text) -> sequence(lines, ind, [])
      key_split(text, n) != nil -> mapping(lines, ind, %{})
      true -> scalar_node(lines)
    end
  end

  defp seq_item?(text), do: text == "-" or String.starts_with?(text, "- ")

  defp sequence([{n, ind, text, raw} | rest] = lines, ind0, acc) when ind == ind0 do
    if seq_item?(text) do
      item_text = text |> String.trim_leading("-") |> String.trim_leading(" ")
      offset = ind + byte_size(text) - byte_size(item_text)
      item_text = strip_comment(item_text, n)

      {value, rest} =
        cond do
          item_text == "" ->
            nested(rest, ind, n)

          true ->
            # "- key: v" starts a mapping at the item's column; "- - x" a
            # nested sequence.
            node_lines = [{n, offset, item_text, raw} | rest]

            if seq_item?(item_text) or key_split(item_text, n) != nil,
              do: node(node_lines, offset),
              else: inline_value(item_text, n, rest, ind)
        end

      sequence(rest, ind0, [value | acc])
    else
      # A key at the same indent ends a sequence that sat under its key.
      _ = n
      {Enum.reverse(acc), lines}
    end
  end

  defp sequence(lines, _ind0, acc), do: {Enum.reverse(acc), lines}

  defp mapping([{n, ind, text, _} | rest], ind0, acc) when ind == ind0 do
    case key_split(text, n) do
      nil ->
        fail(n, "expected a key: value pair")

      {key, value_text} ->
        if Map.has_key?(acc, key), do: fail(n, "duplicate key #{inspect(key)}")
        value_text = strip_comment(value_text, n)

        {value, rest} =
          cond do
            value_text == "" ->
              # A block sequence may sit at the key's own indent.
              case rest do
                [{_, ^ind, t, _} | _] = seq ->
                  if seq_item?(t), do: sequence(seq, ind, []), else: {nil, rest}

                _ ->
                  nested(rest, ind, n)
              end

            true ->
              inline_value(value_text, n, rest, ind)
          end

        mapping(rest, ind0, Map.put(acc, key, value))
    end
  end

  defp mapping([{n, ind, _, _} | _], ind0, _acc) when ind > ind0,
    do: fail(n, "unexpected indentation")

  defp mapping(lines, _ind0, acc), do: {acc, lines}

  # The block node under a key or a "-": the following lines indented more
  # than `ind`, or null when there are none.
  defp nested([{_, i, _, _} | _] = lines, ind, _n) when i > ind, do: node(lines, i)
  defp nested(lines, _ind, _n), do: {nil, lines}

  # A value on the same line as its key or dash: a block scalar header, a
  # flow collection (which may continue on the lines below), or a scalar
  # (a plain one may continue on more-indented lines).
  defp inline_value(text, n, rest, ind) do
    cond do
      String.match?(text, ~r/\A[|>][+-]?[1-9]?[+-]?\z/) ->
        block_scalar(text, n, rest, ind)

      String.starts_with?(text, ["[", "{"]) ->
        {joined, rest} = gather_flow(text, n, rest)
        {flow_document(joined, n), rest}

      true ->
        {more, rest} = Enum.split_while(rest, fn {_, i, _, _} -> i > ind end)

        cond do
          more == [] ->
            {scalar(text, n), rest}

          String.starts_with?(text, ["\"", "'"]) ->
            joined = Enum.join([text | Enum.map(more, &elem(&1, 2))], "\n")
            {scalar(fold_quoted(joined), n), rest}

          true ->
            parts = [text | Enum.map(more, fn {m, _, t, _} -> strip_comment(t, m) end)]

            for {m, _, t, _} <- more,
                key_split(t, m) != nil or seq_item?(t),
                do: fail(m, "unexpected indentation")

            {plain(Enum.join(parts, " "), n), rest}
        end
    end
  end

  # A quoted scalar over several lines: line breaks fold into spaces.
  defp fold_quoted(s), do: s |> String.split("\n") |> Enum.map_join(" ", &String.trim/1)

  defp scalar_node([{n, ind, text, _} | rest]) do
    inline_value(strip_comment(text, n), n, rest, ind - 1)
  end

  # Joins lines until the brackets of a flow collection balance.
  defp gather_flow(text, n, rest) do
    if balanced?(text) do
      {text, rest}
    else
      case rest do
        [{m, _, t, _} | more] -> gather_flow(text <> " " <> strip_comment(t, m), n, more)
        [] -> fail(n, "unterminated flow collection")
      end
    end
  end

  defp balanced?(text) do
    text
    |> String.to_charlist()
    |> Enum.reduce_while({0, nil}, fn
      c, {d, nil} when c in [?[, ?{] -> {:cont, {d + 1, nil}}
      c, {d, nil} when c in [?], ?}] -> {:cont, {d - 1, nil}}
      ?", {d, nil} -> {:cont, {d, ?"}}
      ?', {d, nil} -> {:cont, {d, ?'}}
      ?", {d, ?"} -> {:cont, {d, nil}}
      ?', {d, ?'} -> {:cont, {d, nil}}
      _, acc -> {:cont, acc}
    end)
    |> case do
      {d, nil} -> d <= 0
      _ -> false
    end
  end

  # Literal (|) and folded (>) block scalars, with chomping (+, -) and an
  # optional indentation indicator.
  defp block_scalar(header, n, rest, ind) do
    chomp =
      cond do
        String.contains?(header, "-") -> :strip
        String.contains?(header, "+") -> :keep
        true -> :clip
      end

    explicit =
      case Regex.run(~r/[1-9]/, header) do
        [d] -> ind + String.to_integer(d)
        nil -> nil
      end

    # Block scalar lines are taken from the raw text, blank lines included:
    # every line up to the next one indented no more than the parent.
    {last, rest} =
      case Enum.split_while(rest, fn {_, i, _, _} -> i > ind end) do
        {_, [{m, _, _, _} | _] = after_block} -> {m - 1, after_block}
        {_, []} -> {Process.get(@raw) |> Map.keys() |> Enum.max(), []}
      end

    raw = Process.get(@raw)
    body = for m <- (n + 1)..last//1, do: {m, raw[m]}

    block_ind =
      explicit ||
        Enum.find_value(body, ind + 1, fn {_, r} -> if String.trim(r) != "", do: leading(r) end)

    lines =
      Enum.map(body, fn {m, raw} ->
        cond do
          String.trim(raw) == "" ->
            ""

          leading(raw) < block_ind ->
            fail(m, "block scalar line is indented less than its first line")

          true ->
            binary_part(raw, block_ind, byte_size(raw) - block_ind)
        end
      end)

    text =
      if String.starts_with?(header, "|"),
        do: Enum.join(lines, "\n"),
        else: fold(lines)

    trailing = lines |> Enum.reverse() |> Enum.take_while(&(&1 == "")) |> length()
    core = String.trim_trailing(text, "\n")

    value =
      case chomp do
        :strip -> core
        :clip -> if core == "", do: "", else: core <> "\n"
        :keep -> core <> "\n" <> String.duplicate("\n", trailing)
      end

    {value, rest}
  end

  defp leading(raw), do: byte_size(raw) - byte_size(String.trim_leading(raw, " "))

  # Folding: lines join with a space; an empty line is a newline; more
  # indented lines keep their breaks.
  defp fold(lines) do
    lines
    |> Enum.chunk_by(&(&1 == ""))
    |> Enum.map_join(fn
      ["" | _] = blanks -> String.duplicate("\n", length(blanks))
      words -> Enum.join(words, " ")
    end)
  end

  # ---- keys and comments ------------------------------------------------------

  # Splits "key: value" (or "key:") into {key, value text}, or nil when the
  # line is not a mapping entry.
  defp key_split(text, n) do
    cond do
      String.starts_with?(text, "? ") or text == "?" ->
        fail(n, "complex keys (?) are not supported")

      String.starts_with?(text, "\"") ->
        quoted_key(text, n, ?")

      String.starts_with?(text, "'") ->
        quoted_key(text, n, ?')

      String.starts_with?(text, ["[", "{"]) ->
        nil

      true ->
        case Regex.run(~r/\A([^#][^#]*?)\s*:(?:[ \t]+(.*)|)\z/s, text) do
          [_, key] -> {plain_key(key, n), ""}
          [_, key, v] -> {plain_key(key, n), v}
          nil -> nil
        end
    end
  end

  defp plain_key(key, n) do
    if String.contains?(key, ": "), do: nil, else: key |> String.trim() |> check_plain(n)
  end

  defp check_plain(<<c, _::binary>> = s, n) when c in [?&, ?*, ?!, ?|, ?>, ?%, ?@, ?`],
    do: fail(n, "#{inspect(s)}: anchors, aliases, tags and reserved indicators are not supported")

  defp check_plain(s, _n), do: s

  defp quoted_key(text, n, q) do
    {key, rest} = quoted(text, n, q)

    case Regex.run(~r/\A\s*:(?:[ \t]+(.*)|)\z/s, rest) do
      [_] -> {key, ""}
      [_, v] -> {key, v}
      nil -> nil
    end
  end

  # Removes a trailing comment: a # after whitespace, outside quotes.
  defp strip_comment(text, _n) do
    text
    |> String.to_charlist()
    |> Enum.reduce_while({[], nil, ?\s}, fn
      ?#, {acc, nil, prev} when prev in [?\s, ?\t] -> {:halt, {acc, nil, ?#}}
      c, {acc, nil, _} when c in [?", ?'] -> {:cont, {[c | acc], c, c}}
      c, {acc, q, _} when c == q and q != nil -> {:cont, {[c | acc], nil, c}}
      c, {acc, q, _} -> {:cont, {[c | acc], q, c}}
    end)
    |> then(fn {acc, _q, _} ->
      acc |> Enum.reverse() |> List.to_string() |> String.trim_trailing()
    end)
  end

  # ---- scalars ----------------------------------------------------------------

  defp scalar(text, n) do
    cond do
      String.starts_with?(text, "\"") or String.starts_with?(text, "'") ->
        q = :binary.first(text)
        {s, rest} = quoted(text, n, q)
        if String.trim(rest) != "", do: fail(n, "unexpected text after a quoted string")
        s

      true ->
        plain(text, n)
    end
  end

  defp plain(text, n) do
    text = String.trim(text)
    check_plain(text, n)

    if String.contains?(text, ": ") or String.ends_with?(text, ":"),
      do: fail(n, "a plain value cannot hold \": \"; quote it")

    if String.contains?(text, " #"), do: fail(n, "unexpected comment")
    resolve(text, n)
  end

  # The YAML 1.2 core schema.
  defp resolve(t, n) do
    cond do
      t in ["", "~", "null", "Null", "NULL"] ->
        nil

      t in ["true", "True", "TRUE"] ->
        true

      t in ["false", "False", "FALSE"] ->
        false

      Regex.match?(~r/\A[-+]?[0-9]+\z/, t) ->
        String.to_integer(t)

      Regex.match?(~r/\A0o[0-7]+\z/, t) ->
        t |> binary_part(2, byte_size(t) - 2) |> String.to_integer(8)

      Regex.match?(~r/\A0x[0-9a-fA-F]+\z/, t) ->
        t |> binary_part(2, byte_size(t) - 2) |> String.to_integer(16)

      Regex.match?(~r/\A[-+]?(\.[0-9]+|[0-9]+(\.[0-9]*)?)([eE][-+]?[0-9]+)?\z/, t) ->
        float(t, n)

      Regex.match?(~r/\A[-+]?\.(inf|Inf|INF)\z|\A\.(nan|NaN|NAN)\z/, t) ->
        fail(n, "#{t} has no JSON equivalent")

      true ->
        t
    end
  end

  defp float(t, n) do
    {sign, t} =
      case t do
        "-" <> r -> {"-", r}
        "+" <> r -> {"", r}
        r -> {"", r}
      end

    [mant | exp] = String.split(t, ["e", "E"], parts: 2)

    mant =
      case String.split(mant, ".", parts: 2) do
        ["", f] -> "0." <> f
        [i, ""] -> i <> ".0"
        [i, f] -> i <> "." <> f
        [i] -> i <> ".0"
      end

    case Float.parse(sign <> mant <> if(exp == [], do: "", else: "e" <> hd(exp))) do
      {f, ""} -> f
      _ -> fail(n, "invalid number #{inspect(t)}")
    end
  rescue
    ArgumentError -> fail(n, "number #{inspect(t)} is out of range")
  end

  # A quoted scalar at the head of text: {string, rest of text}.
  defp quoted(<<?', rest::binary>>, n, ?'), do: single(rest, n, "")
  defp quoted(<<?", rest::binary>>, n, ?"), do: double(rest, n, "")

  defp single("''" <> rest, n, acc), do: single(rest, n, acc <> "'")
  defp single("'" <> rest, _n, acc), do: {acc, rest}
  defp single(<<c::utf8, rest::binary>>, n, acc), do: single(rest, n, acc <> <<c::utf8>>)
  defp single("", n, _acc), do: fail(n, "unterminated quoted string")

  defp double("\"" <> rest, _n, acc), do: {acc, rest}

  defp double("\\" <> <<c, rest::binary>>, n, acc) do
    case c do
      ?x ->
        hex(rest, 2, n, acc)

      ?u ->
        hex(rest, 4, n, acc)

      ?U ->
        hex(rest, 8, n, acc)

      _ ->
        esc = %{
          ?0 => <<0>>,
          ?a => "\a",
          ?b => "\b",
          ?t => "\t",
          ?\t => "\t",
          ?n => "\n",
          ?v => "\v",
          ?f => "\f",
          ?r => "\r",
          ?e => "\e",
          ?\s => " ",
          ?" => "\"",
          ?/ => "/",
          ?\\ => "\\",
          ?N => "\u0085",
          ?_ => " ",
          ?L => "\u2028",
          ?P => "\u2029"
        }

        case Map.fetch(esc, c) do
          {:ok, s} -> double(rest, n, acc <> s)
          :error -> fail(n, "invalid escape \\#{<<c>>}")
        end
    end
  end

  defp double(<<c::utf8, rest::binary>>, n, acc), do: double(rest, n, acc <> <<c::utf8>>)
  defp double("", n, _acc), do: fail(n, "unterminated quoted string")

  defp hex(s, len, n, acc) do
    with <<h::binary-size(len), rest::binary>> <- s,
         true <- Regex.match?(~r/\A[0-9A-Fa-f]+\z/, h),
         cp = String.to_integer(h, 16),
         true <- cp <= 0x10FFFF and cp not in 0xD800..0xDFFF do
      double(rest, n, acc <> <<cp::utf8>>)
    else
      _ -> fail(n, "invalid escape")
    end
  end

  # ---- flow collections ---------------------------------------------------------

  defp flow_document(text, n) do
    {v, rest} = flow(String.trim_leading(text), n)

    if String.trim(rest) != "", do: fail(n, "unexpected text after a flow collection")
    v
  end

  defp flow("[" <> rest, n), do: flow_seq(skip(rest), n, [])
  defp flow("{" <> rest, n), do: flow_map(skip(rest), n, %{})

  defp flow(<<q, _::binary>> = s, n) when q in [?", ?'] do
    {v, rest} = quoted(s, n, q)
    {v, skip(rest)}
  end

  defp flow(s, n) do
    case Regex.run(~r/\A[^,\[\]{}]*/, s) do
      [tok] ->
        rest = binary_part(s, byte_size(tok), byte_size(s) - byte_size(tok))
        {plain_flow(tok, n), rest}
    end
  end

  defp plain_flow(tok, n) do
    t = String.trim(tok)
    check_plain(t, n)
    resolve(t, n)
  end

  defp skip(s), do: String.trim_leading(s)

  defp flow_seq("]" <> rest, _n, acc), do: {Enum.reverse(acc), skip(rest)}
  defp flow_seq("", n, _acc), do: fail(n, "unterminated flow sequence")

  defp flow_seq(s, n, acc) do
    {v, rest} = flow(s, n)

    if is_binary(v) and String.contains?(v, ": "),
      do: fail(n, "single-pair mappings in a flow sequence are not supported")

    case skip(rest) do
      "," <> more -> flow_seq(skip(more), n, [v | acc])
      "]" <> more -> {Enum.reverse([v | acc]), skip(more)}
      _ -> fail(n, "expected , or ] in a flow sequence")
    end
  end

  defp flow_map("}" <> rest, _n, acc), do: {acc, skip(rest)}
  defp flow_map("", n, _acc), do: fail(n, "unterminated flow mapping")

  defp flow_map(s, n, acc) do
    {key, rest} =
      case s do
        <<q, _::binary>> when q in [?", ?'] ->
          quoted(s, n, q)

        _ ->
          case Regex.run(~r/\A[^,\[\]{}:]*/, s) do
            [tok] ->
              {tok |> String.trim() |> check_plain(n),
               binary_part(s, byte_size(tok), byte_size(s) - byte_size(tok))}
          end
      end

    if Map.has_key?(acc, key), do: fail(n, "duplicate key #{inspect(key)}")

    {value, rest} =
      case skip(rest) do
        ":" <> more ->
          more = skip(more)

          case more do
            <<c, _::binary>> when c in [?,, ?}] -> {nil, more}
            _ -> flow(more, n)
          end

        other ->
          {nil, other}
      end

    case skip(rest) do
      "," <> more -> flow_map(skip(more), n, Map.put(acc, key, value))
      "}" <> more -> {Map.put(acc, key, value), skip(more)}
      _ -> fail(n, "expected , or } in a flow mapping")
    end
  end
end
