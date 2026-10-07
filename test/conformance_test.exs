defmodule Docuconf.ConformanceTest do
  # The shared conformance suite (SPEC §12), run through contract-first mode.
  # cases.json comes from docuconf-go: DOCUCONF_CONFORMANCE points at it,
  # else ../docuconf-go/conformance/cases.json next to this repository.
  # DOCUCONF_REQUIRE_CONFORMANCE=1 turns a missing file into a failure.
  use ExUnit.Case, async: true

  alias Docuconf.{Duration, ValidationError}

  # Capability tags this SDK supports (conformance/README.md). Elixir
  # integers are exact at any size, and Docuconf.JSONSchema validates json
  # values, so nothing is skipped.
  @supported ["int64", "json-schema"]

  @path System.get_env("DOCUCONF_CONFORMANCE") ||
          Path.expand("../docuconf-go/conformance/cases.json", Path.dirname(__DIR__))

  if File.exists?(@path) do
    @external_resource @path
    @cases @path |> File.read!() |> JSON.decode!() |> Map.fetch!("cases")

    for c <- @cases do
      missing = c["requires"] -- @supported

      if missing != [] do
        @tag skip: "requires #{Enum.join(missing, ", ")}"
      end

      @tag case: c
      test "case #{c["id"]}", %{case: c} do
        run(c)
      end
    end
  else
    if System.get_env("DOCUCONF_REQUIRE_CONFORMANCE") == "1" do
      test "cases.json is present" do
        flunk("DOCUCONF_REQUIRE_CONFORMANCE=1, but #{@path} does not exist")
      end
    else
      @tag skip: "#{@path} not found; set DOCUCONF_CONFORMANCE"
      test "conformance suite", do: :ok
    end
  end

  defp run(c) do
    id = c["id"]
    vars = c["contract"]["vars"]

    log =
      Path.join(System.tmp_dir!(), "docuconf-conformance-#{System.unique_integer([:positive])}")

    result =
      Docuconf.Contract.load(c["contract"], env: c["env"], termination_log: log, warn: false)

    written = File.read(log)
    File.rm(log)

    cond do
      Map.has_key?(c, "expect") ->
        assert {:ok, values} = result, "#{id}: expected success, got #{inspect(result)}"

        for {name, want} <- c["expect"] do
          got = to_json(vars[name], Map.get(values, name))

          assert same?(got, want),
                 "#{id}: #{name} is #{inspect(got)}, expected #{inspect(want)}"
        end

      Map.has_key?(c, "errors") ->
        assert {:error, %ValidationError{violations: vs} = e} = result,
               "#{id}: expected errors, got #{inspect(result)}"

        got = vs |> Enum.map(&{&1.input, Atom.to_string(&1.code)}) |> Enum.sort()
        want = c["errors"] |> Enum.map(&{&1["var"], &1["code"]}) |> Enum.sort()
        assert got == want, "#{id}: errors #{inspect(got)}, expected #{inspect(want)}"

        output = [Exception.message(e) | Enum.map(vs, & &1.message)]
        output = if match?({:ok, _}, written), do: [elem(written, 1) | output], else: output

        for {name, raw} <- secret_values(c), text <- output do
          refute String.contains?(text, raw),
                 "#{id}: the raw value of secret #{name} appears in the error output"
        end
    end
  end

  # The env values that belong to secret variables, including the items of
  # an indexed list (NAME__0, ...).
  defp secret_values(c) do
    for {name, %{"secret" => true}} <- c["contract"]["vars"],
        {key, raw} <- c["env"],
        key == name or String.starts_with?(key, name <> "__"),
        raw != "",
        do: {name, raw}
  end

  defp to_json(_var, nil), do: nil
  defp to_json(%{"type" => "duration"}, ns), do: Duration.format(ns)
  defp to_json(_var, v), do: v

  # int exactly, float numerically (3 equals 3.0), JSON values structurally.
  defp same?(a, b) when is_integer(a) and is_integer(b), do: a == b
  defp same?(a, b) when is_number(a) and is_number(b), do: a == b

  defp same?(a, b) when is_list(a) and is_list(b),
    do: length(a) == length(b) and Enum.all?(Enum.zip(a, b), fn {x, y} -> same?(x, y) end)

  defp same?(%{} = a, %{} = b),
    do:
      map_size(a) == map_size(b) and Enum.all?(a, fn {k, v} -> same?(v, Map.get(b, k, :none)) end)

  defp same?(a, b), do: a === b
end
