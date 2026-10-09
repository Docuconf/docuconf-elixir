defmodule Docuconf.ReadersTest do
  # The built-in YAML and TOML readers that contract-first mode uses for
  # config files and overlays.
  use ExUnit.Case, async: true

  doctest Docuconf.YAML
  doctest Docuconf.TOML

  alias Docuconf.{TOML, YAML}

  describe "YAML" do
    test "block and flow collections, scalars by the core schema" do
      text = """
      ---
      # settings
      name: orders
      replicas: 3
      ratio: 0.5
      enabled: True
      nothing: ~
      empty:
      yes: yes
      octal: 0o17
      hex: 0x1F
      leading: 010
      tags: [a, "b c", 'd''e']
      limits: {burst: 10, rate: [1, 2]}
      url: https://example.test/a#frag   # a comment
      list:
      - one
      - key: v
        other: w
      - - x
        - y
      nested:
        deeper:
          value: "tab\\there"
      literal: |
        line one
        # not a comment

        line three
      folded: >-
        a
        b

        c
      """

      assert YAML.decode(text) ==
               {:ok,
                %{
                  "name" => "orders",
                  "replicas" => 3,
                  "ratio" => 0.5,
                  "enabled" => true,
                  "nothing" => nil,
                  "empty" => nil,
                  "yes" => "yes",
                  "octal" => 15,
                  "hex" => 31,
                  "leading" => 10,
                  "tags" => ["a", "b c", "d'e"],
                  "limits" => %{"burst" => 10, "rate" => [1, 2]},
                  "url" => "https://example.test/a#frag",
                  "list" => ["one", %{"key" => "v", "other" => "w"}, ["x", "y"]],
                  "nested" => %{"deeper" => %{"value" => "tab\there"}},
                  "literal" => "line one\n# not a comment\n\nline three\n",
                  "folded" => "a b\nc"
                }}
    end

    test "a top-level sequence or scalar, and an empty document" do
      assert YAML.decode("- 1\n- 2\n") == {:ok, [1, 2]}
      assert YAML.decode("plain text\n") == {:ok, "plain text"}
      assert YAML.decode("") == {:ok, nil}
      assert YAML.decode("# only a comment\n") == {:ok, nil}
    end

    test "what it does not read is an error, never a guess" do
      for bad <- [
            "name: [orders\n",
            "a: 1\na: 2\n",
            "a: &x 1\nb: *x\n",
            "a: !!str 1\n",
            "a: 1\n---\nb: 2\n",
            "%YAML 1.2\n---\na: 1\n",
            "? complex\n: key\n",
            "a:\n\tb: 1\n",
            "a: .inf\n",
            "a: b: c\n",
            "a: 'open\n"
          ] do
        assert {:error, _} = YAML.decode(bad), inspect(bad)
      end
    end
  end

  describe "TOML" do
    test "tables, arrays of tables, dotted keys and every value form" do
      text = ~S'''
      # settings
      name = "orders"
      replicas = 3
      ratio = 0.5
      enabled = true
      big = 1_000_000
      hex = 0xff
      oct = 0o17
      bin = 0b101
      exp = 1e3
      tags = [
        "a", # first
        'b',
      ]
      site."google.com" = true
      dt = 1979-05-27T07:32:00Z
      ldt = 1979-05-27 07:32:00
      date = 1979-05-27
      time = 07:32:00.5
      inline = {x = 1, y.z = "q"}
      text = """
      Roses \
        are red\tok"""
      raw = \'''
      C:\path\'''

      [limits]
      burst = 10

      [[upstreams]]
      name = "a"
      [[upstreams]]
      name = "b"
      [upstreams.tls]
      verify = false
      '''

      assert TOML.decode(text) ==
               {:ok,
                %{
                  "name" => "orders",
                  "replicas" => 3,
                  "ratio" => 0.5,
                  "enabled" => true,
                  "big" => 1_000_000,
                  "hex" => 255,
                  "oct" => 15,
                  "bin" => 5,
                  "exp" => 1000.0,
                  "tags" => ["a", "b"],
                  "site" => %{"google.com" => true},
                  "dt" => "1979-05-27T07:32:00Z",
                  "ldt" => "1979-05-27T07:32:00",
                  "date" => "1979-05-27",
                  "time" => "07:32:00.5",
                  "inline" => %{"x" => 1, "y" => %{"z" => "q"}},
                  "text" => "Roses are red\tok",
                  "raw" => "C:\\path",
                  "limits" => %{"burst" => 10},
                  "upstreams" => [
                    %{"name" => "a"},
                    %{"name" => "b", "tls" => %{"verify" => false}}
                  ]
                }}
    end

    test "invalid documents are errors" do
      for bad <- [
            "name = orders\n",
            "a = 1\na = 2\n",
            "[a]\n[a]\n",
            "a = 01\n",
            "a = \"x\" b\n",
            "a = \"unterminated\n",
            "a = {x = 1}\n[a]\n",
            "a.b = 1\n[a]\n",
            "a = nan\n",
            "a = 1979-13-01\n",
            "a = [1, 2\n"
          ] do
        assert {:error, _} = TOML.decode(bad), inspect(bad)
      end
    end
  end
end
