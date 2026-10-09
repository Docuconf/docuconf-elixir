defmodule Docuconf.ConformanceExportTest do
  # The shared export fixture (SPEC §11.2 item 3, §12): Docuconf.Test.FixtureEnv
  # declares docuconf-go's conformance/export/fixture.yaml, and its export
  # must match conformance/export/golden.cue as data, compared by
  # `docuconf conformance export --golden`.
  #
  # The golden file is found next to DOCUCONF_CONFORMANCE (cases.json), else
  # in ../docuconf-go. The CLI is DOCUCONF_CLI, else `docuconf` on PATH; it
  # must be built from the same docuconf-go checkout. With
  # DOCUCONF_REQUIRE_CONFORMANCE=1 a missing golden file or CLI fails.
  use ExUnit.Case, async: true

  @moduletag :tmp_dir

  defp golden do
    case System.get_env("DOCUCONF_CONFORMANCE") do
      nil -> Path.expand("../../docuconf-go/conformance/export/golden.cue", __DIR__)
      cases -> Path.join([Path.dirname(cases), "export", "golden.cue"])
    end
  end

  defp cli, do: System.get_env("DOCUCONF_CLI") || System.find_executable("docuconf")

  test "the fixture's export matches the shared golden contract", %{tmp_dir: dir} do
    golden = golden()
    cli = cli()

    cond do
      File.exists?(golden) and cli != nil ->
        exported = Path.join(dir, "exported.cue")
        File.write!(exported, Docuconf.Test.FixtureEnv.export())

        {out, status} =
          System.cmd(cli, ["conformance", "export", "--golden", golden, exported],
            stderr_to_stdout: true
          )

        assert status == 0, "the export does not match #{golden}:\n#{out}"

      System.get_env("DOCUCONF_REQUIRE_CONFORMANCE") == "1" ->
        flunk(
          "DOCUCONF_REQUIRE_CONFORMANCE=1, but #{golden} or the docuconf CLI (DOCUCONF_CLI) is missing"
        )

      true ->
        IO.puts(
          :stderr,
          "skipping the shared export check: #{golden} or the docuconf CLI is missing"
        )
    end
  end

  test "the fixture's export is metadata docuconf-fixture 1.0.0, sorted by name" do
    out = Docuconf.Test.FixtureEnv.export()
    assert out =~ ~s(name: "docuconf-fixture")
    assert out =~ ~s(appVersion: "1.0.0")
    vars = Regex.scan(~r/^\t\t([A-Z][A-Z0-9_]*): \{/m, out) |> Enum.map(&List.last/1)
    assert vars == Enum.sort(vars)
    assert "WEBHOOK_KEYS" in vars
  end
end
