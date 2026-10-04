defmodule Docuconf.DecoderTest do
  use ExUnit.Case, async: true

  # Stands in for a YAML library (YamlElixir.read_from_string/1 has the
  # same shape): "key: value" lines.
  defmodule TinyYAML do
    def decode(text) do
      text
      |> String.split("\n", trim: true)
      |> Enum.reduce_while({:ok, %{}}, fn line, {:ok, acc} ->
        case String.split(line, ": ", parts: 2) do
          [k, v] -> {:cont, {:ok, Map.put(acc, k, v)}}
          _ -> {:halt, {:error, "bad line"}}
        end
      end)
    end
  end

  defmodule Env do
    use Docuconf, name: "yaml-app"

    config_file :settings,
      format: :yaml,
      decoder: &Docuconf.DecoderTest.TinyYAML.decode/1,
      description: "App settings",
      required: true,
      path: "/etc/app/settings.yaml",
      schema: %{"type" => "object", "required" => ["mode"]}
  end

  test "YAML and TOML files use the declared decoder" do
    root = Path.join(System.tmp_dir!(), "docuconf-dec-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(root, "etc/app"))
    file = Path.join(root, "etc/app/settings.yaml")
    opts = [env: %{"DOCUCONF_FILE_ROOT" => root}, termination_log: false, warn: false]

    File.write!(file, "mode: fast\n")
    assert {:ok, %{settings: %{data: %{"mode" => "fast"}}}} = Env.load(opts)

    File.write!(file, "nonsense\n")
    {:error, e} = Env.load(opts)
    assert [%{code: :file_malformed, message: msg}] = e.violations
    assert msg =~ "not valid YAML (bad line)"

    File.write!(file, "other: x\n")
    {:error, e} = Env.load(opts)
    assert [%{code: :schema_mismatch}] = e.violations

    assert Env.export() =~ ~s(format: "yaml")
  end
end
