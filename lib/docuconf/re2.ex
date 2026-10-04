defmodule Docuconf.RE2 do
  @moduledoc """
  RE2 patterns on top of Erlang's PCRE (`:re`).

  SPEC §4.3: patterns are RE2 and match anywhere in the value. PCRE is a
  superset of RE2's syntax, so docuconf rejects the PCRE-only features
  (lookaround, backreferences, atomic groups, possessive quantifiers,
  recursion, conditionals) at declaration time, and compiles the rest with
  `dollar_endonly`, so `$` means end of text as in RE2 rather than "before a
  final newline" as in PCRE.
  """

  @doc """
  Returns `nil` when `pattern` only uses RE2 features, or a description of
  the first PCRE-only feature found.
  """
  @spec non_re2_feature(String.t()) :: String.t() | nil
  def non_re2_feature(pattern), do: scan(pattern, false, nil)

  defp scan("", _in_class, _prev), do: nil

  defp scan("\\" <> rest, in_class, _prev) do
    case rest do
      <<d, _::binary>> when d in ?1..?9 and not in_class ->
        "backreference \\#{<<d>>}"

      "k<" <> _ when not in_class ->
        "named backreference \\k<...>"

      "k{" <> _ when not in_class ->
        "named backreference \\k{...}"

      "g" <> _ when not in_class ->
        "backreference or subroutine \\g"

      "K" <> _ when not in_class ->
        "match reset \\K"

      "Z" <> _ when not in_class ->
        "\\Z (use \\z)"

      <<_::utf8, r::binary>> ->
        scan(r, in_class, :atom)

      "" ->
        "trailing backslash"
    end
  end

  defp scan(<<c::utf8, rest::binary>>, true, _prev) do
    if c == ?], do: scan(rest, false, :atom), else: scan(rest, true, :atom)
  end

  defp scan("[" <> rest, false, _prev) do
    rest = String.replace_prefix(rest, "^", "")

    rest =
      if String.starts_with?(rest, "]"), do: binary_part(rest, 1, byte_size(rest) - 1), else: rest

    scan(rest, true, :atom)
  end

  defp scan("(?" <> rest, false, _prev) do
    cond do
      String.starts_with?(rest, "=") -> "lookahead (?=...)"
      String.starts_with?(rest, "!") -> "negative lookahead (?!...)"
      String.starts_with?(rest, "<=") -> "lookbehind (?<=...)"
      String.starts_with?(rest, "<!") -> "negative lookbehind (?<!...)"
      String.starts_with?(rest, ">") -> "atomic group (?>...)"
      String.starts_with?(rest, "(") -> "conditional (?(...)"
      String.starts_with?(rest, "|") -> "branch reset (?|...)"
      String.starts_with?(rest, "R") -> "recursion (?R)"
      String.starts_with?(rest, "&") -> "subroutine call (?&...)"
      String.starts_with?(rest, "P>") -> "subroutine call (?P>...)"
      String.starts_with?(rest, "P=") -> "named backreference (?P=...)"
      String.starts_with?(rest, "#") -> "comment group (?#...)"
      Regex.match?(~r/^[+-]?[0-9]/, rest) -> "subroutine call (?n)"
      true -> scan(rest, false, :group)
    end
  end

  # A quantifier followed by "+" is possessive in PCRE.
  defp scan(<<q, ?+, _::binary>>, false, prev) when q in [?*, ?+, ??] and prev == :atom,
    do: "possessive quantifier #{<<q>>}+"

  defp scan("}+" <> _, false, _prev), do: "possessive quantifier {n}+"

  defp scan(<<c::utf8, rest::binary>>, false, _prev) do
    prev = if c in [?*, ?+, ??], do: :quant, else: :atom
    scan(rest, false, prev)
  end

  @doc """
  Compiles an RE2 pattern for partial matching with RE2 semantics: `$` is
  end of text, and `\\d`, `\\w`, `\\s`, `\\b` (and their negations) are
  ASCII-only, as in RE2, rather than following PCRE's Latin-1 tables.
  """
  @spec compile(String.t()) :: {:ok, Regex.t()} | {:error, String.t()}
  def compile(pattern) do
    case non_re2_feature(pattern) do
      nil ->
        case Regex.compile(ascii_classes(pattern), [:unicode, :dollar_endonly]) do
          {:ok, re} -> {:ok, re}
          {:error, {msg, pos}} -> {:error, "invalid pattern at #{pos}: #{msg}"}
        end

      feature ->
        {:error, "uses #{feature}, which RE2 does not support"}
    end
  end

  @word "0-9A-Za-z_"
  @space "\\t\\n\\f\\r "
  @outside %{
    ?d => "[0-9]",
    ?D => "[^0-9]",
    ?w => "[#{@word}]",
    ?W => "[^#{@word}]",
    ?s => "[#{@space}]",
    ?S => "[^#{@space}]",
    ?b => "(?:(?<=[#{@word}])(?![#{@word}])|(?<![#{@word}])(?=[#{@word}]))",
    ?B => "(?:(?<=[#{@word}])(?=[#{@word}])|(?<![#{@word}])(?![#{@word}]))"
  }
  @inside %{?d => "0-9", ?w => @word, ?s => @space}

  @doc false
  def ascii_classes(pattern), do: ascii(pattern, false, [])

  defp ascii("", _in_class, acc), do: acc |> Enum.reverse() |> IO.iodata_to_binary()

  defp ascii(<<?\\, c, rest::binary>>, false, acc) when is_map_key(@outside, c),
    do: ascii(rest, false, [@outside[c] | acc])

  defp ascii(<<?\\, c, rest::binary>>, true, acc) when is_map_key(@inside, c),
    do: ascii(rest, true, [@inside[c] | acc])

  defp ascii(<<?\\, c::utf8, rest::binary>>, in_class, acc),
    do: ascii(rest, in_class, [<<?\\, c::utf8>> | acc])

  defp ascii("[" <> rest, false, acc) do
    {open, rest} =
      case rest do
        "^]" <> r -> {"[^]", r}
        "^" <> r -> {"[^", r}
        "]" <> r -> {"[]", r}
        r -> {"[", r}
      end

    ascii(rest, true, [open | acc])
  end

  defp ascii("]" <> rest, true, acc), do: ascii(rest, false, ["]" | acc])

  defp ascii(<<c::utf8, rest::binary>>, in_class, acc),
    do: ascii(rest, in_class, [<<c::utf8>> | acc])

  @doc "Partial match, as CUE `=~` and JSON Schema `pattern` do."
  @spec matches?(Regex.t() | String.t(), String.t()) :: boolean()
  def matches?(pattern, value) when is_binary(pattern) do
    {:ok, re} = compile(pattern)
    matches?(re, value)
  end

  def matches?(%Regex{} = re, value) do
    String.valid?(value) and Regex.match?(re, value)
  end
end
