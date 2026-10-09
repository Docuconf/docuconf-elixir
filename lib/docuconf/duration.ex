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

  @encodings ["go", "iso8601", "seconds", "timespan"]

  @doc "The duration wire encodings of SPEC §5."
  @spec encodings() :: [String.t()]
  def encodings, do: @encodings

  @doc """
  Parses a duration in one of the wire encodings of SPEC §5 into
  nanoseconds:

    * `"go"`: Go syntax, `1m30s` (see `parse/1`);
    * `"iso8601"`: `PT90S`, `PT1.5S`, `P1DT2H3M4.5S` (days, hours, minutes
      and seconds; years, months and weeks have no fixed length and are
      rejected);
    * `"seconds"`: a decimal number of seconds, `90` or `0.25`;
    * `"timespan"`: .NET `TimeSpan`, `[d.]hh:mm:ss[.fffffff]`.

  Fractions are exact down to the nanosecond; finer digits are truncated.

      iex> Docuconf.Duration.parse("PT1.5S", "iso8601")
      {:ok, 1_500_000_000}
      iex> Docuconf.Duration.parse("1.02:03:04.5", "timespan")
      {:ok, 93_784_500_000_000}
      iex> Docuconf.Duration.parse("90s", "seconds")
      :error
  """
  @spec parse(String.t(), String.t()) :: {:ok, nanoseconds()} | :error
  def parse(s, "go"), do: parse(s)

  # SPEC §5: P[nD][T[nH][nM][nS]], where n is digits with an optional
  # fraction after "." or "," (PT1,5S); upper case, unsigned, at least one
  # component, and at least one after a T.
  @iso_num "([0-9]+(?:[.,][0-9]+)?)"
  @iso8601 Regex.compile!(
             "^P(?:#{@iso_num}D)?(?:T(?:#{@iso_num}H)?(?:#{@iso_num}M)?(?:#{@iso_num}S)?)?\\z"
           )

  def parse(s, "iso8601") when is_binary(s) do
    case Regex.run(@iso8601, s) do
      [_ | groups] when s != "P" ->
        if String.ends_with?(s, "T") do
          :error
        else
          [d, h, m, sec] = groups ++ List.duplicate("", 4 - length(groups))
          sum([{d, 86_400}, {h, 3_600}, {m, 60}, {sec, 1}])
        end

      _ ->
        :error
    end
  end

  def parse(s, "seconds") when is_binary(s) do
    if Regex.match?(~r/^[0-9]+(?:\.[0-9]+)?\z/, s), do: sum([{s, 1}]), else: :error
  end

  # SPEC §5: [d.]hh:mm:ss[.f], hh one or two digits below 24, mm and ss two
  # digits below 60, f one to seven digits. Unsigned.
  def parse(s, "timespan") when is_binary(s) do
    case Regex.run(~r/^(?:([0-9]+)\.)?([0-9]{1,2}):([0-9]{2}):([0-9]{2})(?:\.([0-9]{1,7}))?\z/, s) do
      [_ | groups] ->
        [d, h, m, sec, frac] = groups ++ List.duplicate("", 5 - length(groups))
        sec = if frac == "", do: sec, else: sec <> "." <> frac

        if to_i(h) < 24 and to_i(m) < 60 and to_i(sec |> String.split(".") |> hd()) < 60,
          do: sum([{d, 86_400}, {h, 3_600}, {m, 60}, {sec, 1}]),
          else: :error

      nil ->
        :error
    end
  end

  def parse(_, _), do: :error

  defp to_i(""), do: 0
  defp to_i(s), do: String.to_integer(s)

  # The exact sum of decimals ("1.5", "1,5") times their unit in seconds, in
  # nanoseconds, truncated as Go truncates. More than 2^63-1 ns is an error.
  defp sum(parts) do
    terms =
      for {decimal, per} <- parts, decimal != "" do
        {int, frac} =
          case String.split(decimal, [".", ","], parts: 2) do
            [i, f] -> {i, f}
            [i] -> {i, ""}
          end

        {to_i(int <> frac) * per * 1_000_000_000, Integer.pow(10, byte_size(frac))}
      end

    scale = terms |> Enum.map(&elem(&1, 1)) |> Enum.max(fn -> 1 end)
    total = div(Enum.reduce(terms, 0, fn {n, d}, acc -> acc + n * div(scale, d) end), scale)

    if total > @max_ns, do: :error, else: {:ok, total}
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

  @doc """
  Formats nanoseconds in a wire encoding (see `parse/2`).

      iex> Docuconf.Duration.format(30_000_000_000, "iso8601")
      "PT30S"
      iex> Docuconf.Duration.format(5_400_500_000_000, "iso8601")
      "PT1H30M0.5S"
      iex> Docuconf.Duration.format(90_000_000_000, "seconds")
      "90"
      iex> Docuconf.Duration.format(90_000_000_000, "timespan")
      "00:01:30"
  """
  @spec format(nanoseconds(), String.t()) :: String.t()
  def format(ns, "go"), do: format(ns)

  def format(ns, "iso8601") when ns >= 0 do
    {h, m, s, frac} = hms(ns)

    parts =
      [h > 0 && "#{h}H", m > 0 && "#{m}M", (s > 0 or frac != "" or ns == 0) && "#{s}#{frac}S"]
      |> Enum.filter(& &1)

    "PT" <> Enum.join(parts)
  end

  def format(ns, "seconds") when ns >= 0 do
    {_, _, _, frac} = hms(ns)
    "#{div(ns, 1_000_000_000)}#{frac}"
  end

  def format(ns, "timespan") when ns >= 0 do
    {h, m, s, frac} = hms(ns)
    {d, h} = {div(h, 24), rem(h, 24)}
    pad = &String.pad_leading(Integer.to_string(&1), 2, "0")
    if(d > 0, do: "#{d}.", else: "") <> "#{pad.(h)}:#{pad.(m)}:#{pad.(s)}#{frac}"
  end

  def format(ns, _encoding), do: format(ns)

  defp hms(ns) do
    secs = div(ns, 1_000_000_000)
    nanos = rem(ns, 1_000_000_000)

    frac =
      if nanos == 0,
        do: "",
        else:
          "." <>
            (nanos
             |> Integer.to_string()
             |> String.pad_leading(9, "0")
             |> String.trim_trailing("0"))

    {div(secs, 3600), div(rem(secs, 3600), 60), rem(secs, 60), frac}
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

  @doc false
  # An integer in `unit` as nanoseconds; `:error` for `:duration`, which has
  # no integer form.
  def from_unit(i, unit) when is_integer(i) do
    case Map.fetch(@unit_ns, unit) do
      {:ok, per} -> {:ok, i * per}
      :error -> :error
    end
  end

  @doc false
  # An Elixir Duration as nanoseconds; `:error` when it has years or months.
  def from_elixir(%{__struct__: Duration, year: 0, month: 0} = d) do
    {us, _precision} = d.microsecond
    secs = ((d.week * 7 + d.day) * 24 + d.hour) * 3600 + d.minute * 60 + d.second
    {:ok, secs * 1_000_000_000 + us * 1_000}
  end

  def from_elixir(_), do: :error
end
