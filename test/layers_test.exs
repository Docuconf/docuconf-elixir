defmodule Docuconf.LayersTest do
  # Profiles and config-file overlays in contract-first mode (SPEC §4.4,
  # §4.7), beyond the shared suite: declaration problems, secrets in an
  # overlay, and the warnings.
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias Docuconf.{Contract, DeclarationError, ValidationError}

  @moduletag :tmp_dir

  defp contract(extra) do
    Map.merge(
      %{
        "apiVersion" => "docuconf.dev/v1alpha1",
        "kind" => "ConfigContract",
        "metadata" => %{"name" => "catalog"},
        "vars" => %{
          "APP_ENV" => %{"type" => "string", "description" => "Profile name", "default" => "Prod"},
          "PAGE_SIZE" => %{
            "type" => "int",
            "description" => "Items per page",
            "configKey" => "Catalog.PageSize",
            "min" => 1,
            "default" => 10
          },
          "TOKEN" => %{
            "type" => "string",
            "description" => "Partner token",
            "secret" => true,
            "configKey" => "Catalog.Token"
          }
        },
        "profiles" => %{
          "selector" => "APP_ENV",
          "default" => "Prod",
          "defaults" => %{"Prod" => %{"PAGE_SIZE" => 20}}
        },
        "overlays" => %{
          "platform" => %{
            "format" => "yaml",
            "path" => "/app/overlay/platform.yaml",
            "keySeparator" => "."
          }
        }
      },
      extra
    )
  end

  defp overlay(dir, text) do
    path = Path.join(dir, "app/overlay/platform.yaml")
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, text)
  end

  defp load(c, env, dir),
    do: Contract.load(c, env: Map.put(env, "DOCUCONF_FILE_ROOT", dir), warn: false)

  test "layers: default, profile, overlay, environment", %{tmp_dir: dir} do
    c = contract(%{})
    assert {:ok, v} = load(c, %{"APP_ENV" => "Dev"}, dir)
    assert v["PAGE_SIZE"] == 10
    assert {:ok, v} = load(c, %{}, dir)
    assert v["PAGE_SIZE"] == 20
    overlay(dir, "Catalog:\n  PageSize: 30\n")
    assert {:ok, v} = load(c, %{}, dir)
    assert v["PAGE_SIZE"] == 30
    assert {:ok, v} = load(c, %{"PAGE_SIZE" => "40"}, dir)
    assert v["PAGE_SIZE"] == 40
  end

  test "an env value over an overlay value warns, naming the variable", %{tmp_dir: dir} do
    overlay(dir, "Catalog:\n  PageSize: 30\n")

    err =
      capture_io(:stderr, fn ->
        Contract.load(contract(%{}), env: %{"PAGE_SIZE" => "40", "DOCUCONF_FILE_ROOT" => dir})
      end)

    assert err =~
             "PAGE_SIZE is set both in the environment and in an overlay; the environment wins"
  end

  test "a secret in an overlay is invalid_type, and never printed", %{tmp_dir: dir} do
    overlay(dir, "Catalog:\n  Token: tok-in-a-configmap\n")
    assert {:error, %ValidationError{violations: [v]} = e} = load(contract(%{}), %{}, dir)
    assert {v.input, v.code} == {"TOKEN", :invalid_type}
    refute Exception.message(e) =~ "tok-in-a-configmap"
  end

  test "an overlay value is checked like an env value, and named in the message", %{tmp_dir: dir} do
    overlay(dir, "Catalog:\n  PageSize: 0\n")
    assert {:error, e} = load(contract(%{}), %{}, dir)
    assert Exception.message(e) =~ "PAGE_SIZE [out_of_range]: from overlay platform:"
  end

  test "declaration problems in profiles and overlays" do
    bad =
      contract(%{
        "profiles" => %{
          "selector" => "NOPE",
          "default" => "Prod",
          "defaults" => %{
            "Prod" => %{"PAGE_SIZE" => 0, "TOKEN" => "x", "UNKNOWN" => 1}
          }
        },
        "overlays" => %{
          "Bad_Name" => %{"format" => "ini", "path" => "relative", "keySeparator" => "/"},
          "watched" => %{
            "format" => "json",
            "path" => "/app/w/o.json",
            "keySeparator" => ":",
            "reload" => "watch"
          },
          "root" => %{"format" => "json", "path" => "/etc/o.json", "keySeparator" => ":"}
        }
      })

    assert {:error, %DeclarationError{problems: ps}} = Contract.load(bad, env: %{}, warn: false)
    text = Enum.join(ps, "\n")
    assert text =~ ~s(profiles.selector "NOPE" must be a declared variable)
    assert text =~ "profiles.defaults.Prod: PAGE_SIZE: "
    assert text =~ "profiles.defaults.Prod: TOKEN is secret"
    assert text =~ "profiles.defaults.Prod: UNKNOWN is not a declared variable"
    assert text =~ "overlay Bad_Name: name must be a DNS label"
    assert text =~ "overlay Bad_Name: format must be json, yaml or toml"
    assert text =~ "overlay Bad_Name: path \"relative\" must be absolute"
    assert text =~ "overlay Bad_Name: keySeparator must be"
    assert text =~ ~s(overlay watched: reload "watch" is not supported in contract-first mode)
    assert text =~ "overlay root would be mounted at reserved directory /etc"
  end
end
