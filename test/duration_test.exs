defmodule Docuconf.DurationTest do
  use ExUnit.Case, async: true
  doctest Docuconf.Duration

  alias Docuconf.Duration

  test "parses Go syntax like time.ParseDuration" do
    assert Duration.parse("0") == {:ok, 0}
    assert Duration.parse("300ms") == {:ok, 300_000_000}
    assert Duration.parse("2h45m") == {:ok, (2 * 3600 + 45 * 60) * 1_000_000_000}
    assert Duration.parse("1.5s") == {:ok, 1_500_000_000}
    assert Duration.parse(".5s") == {:ok, 500_000_000}
    assert Duration.parse("1us") == {:ok, 1_000}
    assert Duration.parse("1µs") == {:ok, 1_000}
    assert Duration.parse("-1m") == {:ok, -60_000_000_000}

    for bad <- ["", "1", "s", "1x", "1.s.", ".s", "1h 2m", " 1s", "1s ", "PT90S", "00:01:30"] do
      assert Duration.parse(bad) == :error, "expected #{inspect(bad)} to be rejected"
    end
  end

  test "parses every wire encoding" do
    s = 1_000_000_000
    assert Duration.parse("1m30s", "go") == {:ok, 90 * s}
    assert Duration.parse("PT90S", "iso8601") == {:ok, 90 * s}
    assert Duration.parse("PT0.25S", "iso8601") == {:ok, div(s, 4)}
    assert Duration.parse("P1DT2H3M4.5S", "iso8601") == {:ok, 93_784 * s + div(s, 2)}
    assert Duration.parse("PT0S", "iso8601") == {:ok, 0}
    assert Duration.parse("90", "seconds") == {:ok, 90 * s}
    assert Duration.parse("0.001", "seconds") == {:ok, 1_000_000}
    assert Duration.parse("00:01:30", "timespan") == {:ok, 90 * s}
    assert Duration.parse("2.00:00:00", "timespan") == {:ok, 172_800 * s}
    assert Duration.parse("00:00:00.1234567", "timespan") == {:ok, 123_456_700}

    for {bad, enc} <- [
          {"P", "iso8601"},
          {"PT", "iso8601"},
          {"P1DT", "iso8601"},
          {"P1Y", "iso8601"},
          {"P1W", "iso8601"},
          {"pt90s", "iso8601"},
          {"1m30s", "iso8601"},
          {"90s", "seconds"},
          {"-1", "seconds"},
          {".5", "seconds"},
          {"1e3", "seconds"},
          {"00:60:00", "timespan"},
          {"24:00:00", "timespan"},
          {"1:30", "timespan"},
          {"1m30s", "timespan"},
          {"1s", "fortnights"}
        ] do
      assert Duration.parse(bad, enc) == :error,
             "expected #{inspect(bad)} (#{enc}) to be rejected"
    end
  end

  test "formats in canonical Go form" do
    assert Duration.canonical("90m") == {:ok, "1h30m"}
    assert Duration.canonical("1.5h") == {:ok, "1h30m"}
    assert Duration.canonical("720h") == {:ok, "720h"}
    assert Duration.canonical("1500us") == {:ok, "1ms500us"}
  end

  test "converts to the app's unit only when exact" do
    assert Duration.to_unit(1_500_000_000, :millisecond) == {:ok, 1500}
    assert Duration.to_unit(1_500_000_000, :second) == :error

    assert {:ok, %Elixir.Duration{second: 1, microsecond: {500_000, 6}}} =
             Duration.to_unit(1_500_000_000, :duration)
  end
end
