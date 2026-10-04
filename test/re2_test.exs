defmodule Docuconf.RE2Test do
  use ExUnit.Case, async: true
  alias Docuconf.RE2

  test "accepts RE2 syntax" do
    for p <- ["^[a-z]+$", "(?i)abc", "(?:a|b)+?", "(?P<name>x)", "\\d{2,3}", "[(?=]", "a{2}"] do
      assert RE2.non_re2_feature(p) == nil, p
      assert {:ok, _} = RE2.compile(p)
    end
  end

  test "rejects PCRE-only features" do
    for p <- [
          "a(?=b)",
          "a(?!b)",
          "(?<=a)b",
          "(?<!a)b",
          "(a)\\1",
          "(?<n>a)\\k<n>",
          "(?>a)",
          "a*+",
          "a++",
          "(?R)",
          "(?(1)a|b)"
        ] do
      assert RE2.non_re2_feature(p) != nil, p
      assert {:error, _} = RE2.compile(p)
    end
  end

  test "matches anywhere, and $ is end of text as in RE2" do
    assert RE2.matches?("b", "abc")
    refute RE2.matches?("^b", "abc")
    refute RE2.matches?("^abc$", "abc\n")
    assert RE2.matches?("^abc\\n?$", "abc\n")
  end

  test "\\d, \\w, \\s and \\b are ASCII-only, as in RE2" do
    refute RE2.matches?("^\\d$", "٣")
    refute RE2.matches?("^\\w$", "é")
    refute RE2.matches?("^\\s$", "\u00A0")
    assert RE2.matches?("^\\d\\w$", "1a")
    # . still matches a whole code point.
    assert RE2.matches?("^.$", "é")
  end
end
