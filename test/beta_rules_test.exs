defmodule Docuconf.BetaRulesTest do
  # Deprecated inputs (SPEC §4.2, §11.2) and the exact parsing rules of
  # SPEC §5, through the `use Docuconf` DSL.
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias Docuconf.{DeclarationError, Duration}

  defp compile(body) do
    Code.compile_string("""
    defmodule Docuconf.BetaRulesTest.M#{System.unique_integer([:positive])} do
      use Docuconf, name: "rules"
      #{body}
    end
    """)
  end

  defp declaration_error(body) do
    e = assert_raise DeclarationError, fn -> compile(body) end
    Exception.message(e)
  end

  describe "deprecated" do
    test "the message must not be blank and is at most 500 characters" do
      assert declaration_error(~s(env :old, :integer, description: "Old port", deprecated: "  ")) =~
               "deprecated message must not be blank"

      assert declaration_error(
               ~s(env :old, :integer, description: "Old port", deprecated: [replaced_by: :port])
             ) =~ "deprecated message must not be blank"

      long = String.duplicate("x", 501)

      assert declaration_error(
               ~s(env :old, :integer, description: "Old port", deprecated: "#{long}")
             ) =~ "deprecated message is 501 characters, more than 500"

      # 500 characters (code points) is fine.
      [{_, _}] =
        compile(
          ~s(env :old, :integer, description: "Old port", deprecated: "#{String.duplicate("é", 500)}")
        )
    end

    test "a required input cannot be deprecated" do
      assert declaration_error(
               ~s(env :old, :integer, description: "Old port", required: true, deprecated: "Use PORT")
             ) =~ "a required input cannot be deprecated"

      assert declaration_error(
               ~s(text_file :lic, description: "Licence key", path: "/etc/a/lic", required: true, deprecated: "Gone")
             ) =~ "a required input cannot be deprecated"
    end

    test "replaced_by names a field or an input, and is exported" do
      [{mod, _}] =
        compile("""
        env :port, :integer, description: "Listen port", default: 8080
        env :old_port, :integer, description: "Old port", deprecated: [message: "Use PORT instead", replaced_by: :port]
        env :older_port, :integer, description: "Older port", deprecated: [message: "Use PORT", replaced_by: "PORT"]
        binary_file :geoip, description: "GeoIP data", path: "/data/a/g.mmdb", deprecated: [message: "Use geo-db", replaced_by: :geo_db]
        binary_file :geo_db, description: "Geo database", path: "/data/b/g.mmdb"
        """)

      out = mod.export()
      assert out =~ ~r/OLD_PORT: \{.*?replacedBy: "PORT"/s
      assert out =~ ~r/OLDER_PORT: \{.*?replacedBy: "PORT"/s
      assert out =~ ~r/geoip: \{.*?replacedBy: "geo-db"/s
    end

    test "a deprecated variable that is set loads, is checked, and warns without its value" do
      [{mod, _}] =
        compile("""
        env :port, :integer, description: "Listen port", default: 8080
        env :old_port, :integer, description: "Old port", min: 1, deprecated: [message: "Use PORT instead", replaced_by: :port]
        secret :old_token, :string, description: "Old token", deprecated: "The API takes no token"
        """)

      err =
        capture_io(:stderr, fn ->
          assert {:ok, %{old_port: 9090, old_token: "tok-0123456789"}} =
                   mod.load(env: %{"OLD_PORT" => "9090", "OLD_TOKEN" => "tok-0123456789"})
        end)

      assert err =~ "OLD_PORT is deprecated (replaced by PORT): Use PORT instead"
      assert err =~ "OLD_TOKEN is deprecated: The API takes no token"
      refute err =~ "9090"
      refute err =~ "tok-0123456789"

      # Unset, it does not warn; set out of range, it is still an error.
      assert capture_io(:stderr, fn -> {:ok, _} = mod.load(env: %{}) end) == ""

      capture_io(:stderr, fn ->
        assert {:error, e} = mod.load(env: %{"OLD_PORT" => "0"})
        assert Enum.map(e.violations, & &1.code) == [:out_of_range]
      end)
    end
  end

  describe "strict parsing (SPEC §5)" do
    setup do
      [{mod, _}] =
        compile("""
        env :flag, :boolean, description: "A flag"
        env :count, :integer, description: "A count"
        env :ratio, :float, description: "A ratio"
        env :wait, :duration, description: "A wait"
        env :wait_iso, :duration, description: "An ISO wait", encoding: :iso8601
        env :wait_s, :duration, description: "A wait in seconds", encoding: :seconds
        env :wait_ts, :duration, description: "A TimeSpan wait", encoding: :timespan
        env :ids, {:list, :integer}, description: "Some ids"
        env :names, {:list, :string}, description: "Some names"
        """)

      %{mod: mod}
    end

    defp value(mod, name, raw) do
      case mod.load(env: %{name => raw}, warn: false) do
        {:ok, env} -> {:ok, Map.fetch!(env, name |> String.downcase() |> String.to_atom())}
        {:error, e} -> {:error, e.violations |> hd() |> Map.fetch!(:code)}
      end
    end

    test "bool is true or false in any case, and nothing else", %{mod: mod} do
      for ok <- ~w(true TRUE True false FALSE fAlSe) do
        assert {:ok, b} = value(mod, "FLAG", ok)
        assert b == (String.downcase(ok) == "true")
      end

      for bad <- ["1", "0", "t", "f", "yes", "no", "on", "off", " true", "true\n"] do
        assert value(mod, "FLAG", bad) == {:error, :invalid_type}, inspect(bad)
      end
    end

    test "int is ^[+-]?[0-9]+$ in base 10", %{mod: mod} do
      assert value(mod, "COUNT", "+7") == {:ok, 7}
      assert value(mod, "COUNT", "007") == {:ok, 7}
      assert value(mod, "COUNT", "010") == {:ok, 10}
      assert value(mod, "COUNT", "-9223372036854775808") == {:ok, -9_223_372_036_854_775_808}
      assert value(mod, "COUNT", "9223372036854775808") == {:error, :out_of_range}

      for bad <- ["0x10", "0o17", "0b101", "1_000", "1e3", "1.0", " 1", "1 ", "١"] do
        assert value(mod, "COUNT", bad) == {:error, :invalid_type}, inspect(bad)
      end
    end

    test "float needs a digit on each side of the point", %{mod: mod} do
      assert value(mod, "RATIO", "0.5") == {:ok, 0.5}
      assert value(mod, "RATIO", "+5") == {:ok, 5.0}
      assert value(mod, "RATIO", "1E3") == {:ok, 1000.0}
      assert value(mod, "RATIO", "-2.5e-3") == {:ok, -0.0025}

      for bad <- [".5", "5.", "0x1p4", "inf", "Infinity", "NaN", "1_0", "0,5", "1e400", " 1"] do
        assert value(mod, "RATIO", bad) == {:error, :invalid_type}, inspect(bad)
      end
    end

    test "durations follow their encoding's grammar", %{mod: mod} do
      ms = fn v -> {:ok, v} end
      assert value(mod, "WAIT", "1m30s") == ms.(90_000)
      assert value(mod, "WAIT", "+5s") == ms.(5_000)
      assert value(mod, "WAIT", "1.s") == ms.(1_000)
      assert value(mod, "WAIT", "0") == ms.(0)

      for bad <- ["5", "5S", "1d", "1m 30s", " 5s", "5s "],
          do: assert(value(mod, "WAIT", bad) == {:error, :invalid_type}, inspect(bad))

      assert value(mod, "WAIT_ISO", "PT1,5S") == ms.(1_500)
      assert value(mod, "WAIT_ISO", "PT1.5M") == ms.(90_000)
      assert value(mod, "WAIT_ISO", "P1DT2H") == ms.(93_600_000)

      for bad <- ["pt90s", "PT", "P", "P1W", "P1M", "-PT5S", "PT5S "],
          do: assert(value(mod, "WAIT_ISO", bad) == {:error, :invalid_type}, inspect(bad))

      assert value(mod, "WAIT_S", "1.5") == ms.(1_500)

      for bad <- ["-1", "1e3", ".5", "1.", "90s"],
          do: assert(value(mod, "WAIT_S", bad) == {:error, :invalid_type}, inspect(bad))

      assert value(mod, "WAIT_TS", "1.02:03:04.5") == ms.(93_784_500)
      assert value(mod, "WAIT_TS", "0:00:05") == ms.(5_000)

      for bad <- ["01:30", "24:00:00", "00:60:00", "-00:00:05", "00:0:05", "00:00:05.12345678"],
          do: assert(value(mod, "WAIT_TS", bad) == {:error, :invalid_type}, inspect(bad))
    end

    test "csv items are never trimmed", %{mod: mod} do
      assert value(mod, "NAMES", "a, b") == {:ok, ["a", " b"]}
      assert value(mod, "NAMES", "a,,b") == {:ok, ["a", "", "b"]}
      assert value(mod, "IDS", "1,2") == {:ok, [1, 2]}
      assert value(mod, "IDS", "1, 2") == {:error, :invalid_type}
      assert value(mod, "IDS", "1,,2") == {:error, :invalid_type}
    end

    test "exact fractions, truncated to the nanosecond" do
      assert Duration.parse("PT0.0000000015S", "iso8601") == {:ok, 1}
      assert Duration.parse("00:00:00.1234567", "timespan") == {:ok, 123_456_700}
    end
  end
end
