defmodule Docuconf.ConformanceTest do
  # The shared conformance suite (SPEC §12), run through contract-first mode.
  # cases.json comes from docuconf-go: DOCUCONF_CONFORMANCE points at it,
  # else ../docuconf-go/conformance/cases.json next to this repository.
  # DOCUCONF_REQUIRE_CONFORMANCE=1 turns a missing file into a failure.
  use ExUnit.Case, async: true

  @moduletag :tmp_dir

  alias Docuconf.{Duration, KeySet, LoadedFile, ValidationError}

  # The capability tags this SDK supports (conformance/README.md). It is an
  # allow-list: a case that requires any other tag, including one this
  # runner has never heard of, is skipped, never run (SPEC §12). Elixir
  # integers are exact at any size (int64), Docuconf.JSONSchema validates
  # json values (json-schema), and contract-first mode has the keySet type,
  # deprecated inputs, strict parsing, file inputs, profiles and overlays.
  # "the suite skips nothing" below fails on any skip.
  @supported ~w(int64 json-schema key-set deprecated strict-parsing files profiles overlays)

  @path System.get_env("DOCUCONF_CONFORMANCE") ||
          Path.expand("../docuconf-go/conformance/cases.json", Path.dirname(__DIR__))

  if File.exists?(@path) do
    @external_resource @path
    @suite @path |> File.read!() |> JSON.decode!()
    @cases Map.fetch!(@suite, "cases")
    @skipped for c <- @cases, c["requires"] -- @supported != [], do: c

    test "the suite is version 1 and has cases" do
      assert @suite["version"] == 1
      assert length(@cases) > 0
    end

    # The target is no skipped case: every tag in the suite is supported.
    test "the suite skips nothing" do
      skipped =
        @skipped
        |> Enum.flat_map(&(&1["requires"] -- @supported))
        |> Enum.frequencies()

      IO.puts(
        "\nconformance: #{length(@cases)} cases, #{length(@skipped)} skipped #{inspect(skipped)}"
      )

      assert @skipped == [],
             "this SDK must run every case, but skipped #{length(@skipped)}: #{inspect(skipped)}"
    end

    for c <- @cases do
      missing = c["requires"] -- @supported

      if missing != [] do
        @tag skip: "requires #{Enum.join(missing, ", ")}"
      end

      @tag case: c
      test "case #{c["id"]}", %{case: c, tmp_dir: root} do
        run(c, root)
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

  defp run(c, root) do
    id = c["id"]
    contract = c["contract"]

    # Every case gets a fresh, empty file root, files or not, so that no
    # case reads the machine's own files. Each file is written under it at
    # its absolute path.
    File.rm_rf!(root)
    File.mkdir_p!(root)

    for {path, content} <- c["files"] || %{} do
      full = Path.join(root, path)
      File.mkdir_p!(Path.dirname(full))
      File.write!(full, file_bytes(content))
    end

    log = Path.join(root, "termination-log")
    env = Map.put(c["env"], "DOCUCONF_FILE_ROOT", root)

    result =
      Docuconf.Contract.load(contract,
        env: env,
        termination_log: log,
        warn: false,
        duration_unit: :nanosecond
      )

    written = File.read(log)

    cond do
      Map.has_key?(c, "expect") ->
        assert {:ok, values} = result, "#{id}: expected success, got #{inspect(result)}"

        for {name, want} <- c["expect"] do
          got = to_json(input(contract, name), values[name])

          assert same?(got, want),
                 "#{id}: #{name} is #{inspect(got)}, expected #{inspect(want)}"
        end

      Map.has_key?(c, "errors") ->
        assert {:error, %ValidationError{violations: vs} = e} = result,
               "#{id}: expected errors, got #{inspect(result)}"

        got = vs |> Enum.map(&{&1.input, Atom.to_string(&1.code)}) |> Enum.sort()
        want = c["errors"] |> Enum.map(&{&1["var"], &1["code"]}) |> Enum.sort()
        assert got == want, "#{id}: errors #{inspect(got)}, expected #{inspect(want)}"

        output = [Exception.message(e), inspect(e) | Enum.map(vs, & &1.message)]
        output = if match?({:ok, _}, written), do: [elem(written, 1) | output], else: output

        for {name, raw} <- secret_values(c), text <- output do
          refute String.contains?(text, raw),
                 "#{id}: the raw value of secret #{name} appears in the error output"
        end
    end
  end

  defp file_bytes(%{"text" => text}), do: text
  defp file_bytes(%{"base64" => b64}), do: Base.decode64!(b64)

  defp input(contract, name) do
    case get_in(contract, ["vars", name]) do
      nil -> get_in(contract, ["files", name]) |> Map.put("file", true)
      var -> var
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

  defp to_json(_input, nil), do: nil
  defp to_json(%{"type" => "duration"}, ns), do: Duration.format(ns)
  defp to_json(%{"type" => "keySet"}, %KeySet{} = ks), do: KeySet.keys(ks)

  defp to_json(%{"file" => true, "type" => t}, %LoadedFile{data: d}) when t in ~w(config text),
    do: d

  defp to_json(%{"file" => true}, %LoadedFile{}), do: true
  defp to_json(_input, v), do: v

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
