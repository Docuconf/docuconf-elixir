defmodule Docuconf.Duration do
  @moduledoc """
  Go-syntax durations (`1m30s`, `250ms`, `1.5h`), the `go` wire encoding of
  SPEC §5.

  Elixir has no standard duration string format, so docuconf parses Go's
  syntax itself, exactly as `time.ParseDuration` does, and writes durations
  into the contract in canonical Go form (`1h30m`, never `90m` or `1.5h`).
  """

  @units [
    {"ns", 1},
    {"us", 1_000},
    {"µs", 1_000},
    {"μs", 1_000},
    {"ms", 1_000_000},
    {"s", 1_000_000_000},
    {"m", 60_000_000_000},
    {"h", 3_600_000_000_000}
  ]

  @max_ns 9_223_372_036_854_775_807

  @typedoc "A duration in nanoseconds."
  @type nanoseconds :: integer()

  @doc """
  Parses a Go duration string into nanoseconds.

      iex> Docuconf.Duration.parse("1m30s")
      {:ok, 90_000_000_000}
      iex> Docuconf.Duration.parse("1.5h")
      {:ok, 5_400_000_000_000}
      iex> Docuconf.Duration.parse("90")
      :error
  """
  @spec parse(String.t()) :: {:ok, nanoseconds()} | :error
  def parse(s) when is_binary(s) do
    {sign, rest} =
      case s do
        "-" <> r -> {-1, r}
        "+" <> r -> {1, r}
        r -> {1, r}
      end

    cond do
      rest == "0" -> {:ok, 0}
      rest == "" -> :error
      true -> parse_terms(rest, 0, sign)
    end
  end

  def parse(_), do: :error

  defp parse_terms("", acc, sign) do
    if acc > @max_ns, do: :error, else: {:ok, sign * acc}
  end

  defp parse_terms(s, acc, sign) do
    with {int, frac, rest} when int != "" or frac != "" <- take_number(s),
         {unit, rest} <- take_unit(rest) do
      whole = if int == "", do: 0, else: String.to_integer(int)
      # Exact arithmetic: fractional digits scaled by the unit, truncated as
      # Go does.
      frac_ns =
        if frac == "",
          do: 0,
          else: div(String.to_integer(frac) * unit, Integer.pow(10, byte_size(frac)))

      parse_terms(rest, acc + whole * unit + frac_ns, sign)
    else
      _ -> :error
    end
  end

  defp take_number(s) do
    {int, rest} = take_digits(s, "")

    case rest do
      "." <> r ->
        {frac, rest2} = take_digits(r, "")
        {int, frac, rest2}

      _ ->
        {int, "", rest}
    end
  end

  defp take_digits(<<c, rest::binary>>, acc) when c in ?0..?9, do: take_digits(rest, acc <> <<c>>)
  defp take_digits(rest, acc), do: {acc, rest}

  defp take_unit(s) do
    # Longest match first: "ms" before "m", "ns"/"us" before "s".
    Enum.find_value(Enum.sort_by(@units, fn {u, _} -> -byte_size(u) end), :error, fn {u, mult} ->
      case s do
        <<^u::binary-size(byte_size(u)), rest::binary>> -> {mult, rest}
        _ -> nil
      end
    end)
  end

  @doc """
  Formats nanoseconds in canonical Go form, as the contract requires.

      iex> Docuconf.Duration.format(90_000_000_000)
      "1m30s"
      iex> Docuconf.Duration.format(5_400_000_000_000)
      "1h30m"
      iex> Docuconf.Duration.format(1_500_000_000)
      "1s500ms"
      iex> Docuconf.Duration.format(0)
      "0s"
  """
  @spec format(nanoseconds()) :: String.t()
  def format(0), do: "0s"
  def format(ns) when ns < 0, do: "-" <> format(-ns)

  def format(ns) when is_integer(ns) do
    {parts, _} =
      Enum.reduce(
        [
          {"h", 3_600_000_000_000},
          {"m", 60_000_000_000},
          {"s", 1_000_000_000},
          {"ms", 1_000_000},
          {"us", 1_000},
          {"ns", 1}
        ],
        {[], ns},
        fn {name, unit}, {acc, left} ->
          n = div(left, unit)
          if n > 0, do: {[acc, Integer.to_string(n), name], left - n * unit}, else: {acc, left}
        end
      )

    IO.iodata_to_binary(parts)
  end

  @doc "Canonicalises a Go duration string (`90m` becomes `1h30m`)."
  @spec canonical(String.t()) :: {:ok, String.t()} | :error
  def canonical(s) do
    with {:ok, ns} <- parse(s), do: {:ok, format(ns)}
  end

  @unit_ns %{nanosecond: 1, microsecond: 1_000, millisecond: 1_000_000, second: 1_000_000_000}

  @doc """
  Converts nanoseconds to the value exposed to the app for `unit`:
  an integer in `:nanosecond`, `:microsecond`, `:millisecond` (the default,
  matching OTP timeouts) or `:second`, or an Elixir `Duration` for
  `:duration`. Returns `:error` when the duration is not a whole number of
  `unit`s.
  """
  @spec to_unit(nanoseconds(), atom()) :: {:ok, integer() | Duration.t()} | :error
  def to_unit(ns, :duration) do
    if rem(ns, 1_000) == 0 do
      us = div(ns, 1_000)

      case rem(us, 1_000_000) do
        0 -> {:ok, Duration.new!(second: div(us, 1_000_000))}
        frac -> {:ok, Duration.new!(second: div(us, 1_000_000), microsecond: {frac, 6})}
      end
    else
      :error
    end
  end

  def to_unit(ns, unit) do
    per = Map.fetch!(@unit_ns, unit)
    if rem(ns, per) == 0, do: {:ok, div(ns, per)}, else: :error
  end

  @doc false
  def units, do: Map.keys(@unit_ns) ++ [:duration]
end
