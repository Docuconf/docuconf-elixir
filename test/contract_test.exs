defmodule Docuconf.ContractTest do
  use ExUnit.Case, async: true

  alias Docuconf.{Contract, DeclarationError, ValidationError}
  alias Docuconf.Contract.Values

  @contract %{
    "apiVersion" => "docuconf.dev/v1alpha1",
    "kind" => "ConfigContract",
    "metadata" => %{
      "name" => "orders",
      "generator" => %{"language" => "elixir", "sdk" => "docuconf", "version" => "0.1.0"}
    },
    "vars" => %{
      "PORT" => %{"type" => "int", "description" => "HTTP listen port", "default" => 8080},
      "TIMEOUT" => %{
        "type" => "duration",
        "description" => "Request timeout",
        "encoding" => "timespan",
        "max" => "1h"
      },
      "PARTITIONS" => %{
        "type" => "list",
        "description" => "Partitions to consume",
        "items" => "int",
        "encoding" => "indexed",
        "itemMin" => 0,
        "itemMax" => 2_147_483_647
      },
      "TAGS" => %{
        "type" => "list",
        "description" => "Tags to apply",
        "items" => "string",
        "encoding" => "json",
        "maxItems" => 2
      },
      "TOKEN" => %{
        "type" => "string",
        "description" => "Partner API token",
        "secret" => true,
        "minLength" => 8
      }
    }
  }

  defp load(env, contract \\ @contract),
    do: Contract.load(contract, env: env, termination_log: false, warn: false)

  defp codes({:error, %ValidationError{violations: vs}}), do: Enum.map(vs, &{&1.input, &1.code})

  test "loads typed values keyed by name, from a map or JSON" do
    env = %{
      "TIMEOUT" => "00:01:30.5",
      "PARTITIONS__0" => "3",
      "PARTITIONS__1" => "7",
      "PARTITIONS__HOST" => "not an item",
      "TAGS" => ~s(["a","b"]),
      "TOKEN" => "tok_12345678"
    }

    assert {:ok, values} = load(env)

    # Durations are milliseconds by default, as in the DSL.
    assert Values.to_map(values) == %{
             "PORT" => 8080,
             "TIMEOUT" => 90_500,
             "PARTITIONS" => [3, 7],
             "TAGS" => ["a", "b"],
             "TOKEN" => "tok_12345678"
           }

    assert {:ok, ^values} = load(env, JSON.encode!(@contract))

    assert values["PORT"] == 8080
    assert get_in(values, ["TAGS"]) == ["a", "b"]

    assert {:ok, %Values{values: %{"TIMEOUT" => 90_500_000_000}}} =
             Contract.load(@contract,
               env: env,
               duration_unit: :nanosecond,
               termination_log: false,
               warn: false
             )
  end

  test "inspect redacts secret values" do
    assert {:ok, values} = load(%{"TOKEN" => "tok_12345678"})
    shown = inspect(values)
    refute shown =~ "tok_12345678"
    assert shown =~ ~s("TOKEN" => **redacted**)
    assert shown =~ ~s("PORT" => 8080)
  end

  test "absent optional values are nil" do
    assert {:ok, %Values{values: %{"TIMEOUT" => nil, "PARTITIONS" => nil, "TAGS" => nil}}} =
             load(%{})
  end

  test "reports every violation, and never a secret's value" do
    env = %{
      "PORT" => "http",
      "TIMEOUT" => "1h30m",
      "PARTITIONS__0" => "-1",
      "TAGS" => ~s(["a","b","c"]),
      "TOKEN" => "s3cr3t"
    }

    assert {:error, %ValidationError{} = e} = result = load(env)

    assert codes(result) == [
             {"PARTITIONS", :out_of_range},
             {"PORT", :invalid_type},
             {"TAGS", :too_many_items},
             {"TIMEOUT", :invalid_type},
             {"TOKEN", :out_of_range}
           ]

    refute Exception.message(e) =~ "s3cr3t"
  end

  test "writes the termination log" do
    log = Path.join(System.tmp_dir!(), "docuconf-contract-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm(log) end)
    assert {:error, _} = Contract.load(@contract, env: %{"PORT" => "x"}, termination_log: log)
    assert File.read!(log) =~ "PORT [invalid_type]"
  end

  test "an invalid contract is a DeclarationError" do
    bad =
      @contract
      |> put_in(["vars", "PORT", "description"], "port")
      |> put_in(["vars", "TAGS", "itemMax"], 3)
      |> put_in(["vars", "EXTRA"], %{"type" => "uuid", "description" => "Unknown type"})
      |> put_in(["vars", "TOKEN", "colour"], "blue")

    assert {:error, %DeclarationError{problems: ps}} = load(%{}, bad)
    text = Enum.join(ps, "\n")
    assert text =~ "env EXTRA: unknown type \"uuid\""
    assert text =~ "env TOKEN: unknown fields [\"colour\"]"
    assert text =~ "(PORT): description is required"
    assert text =~ "(TAGS): item_min and item_max apply only to {:list, :integer}"

    assert {:error, %DeclarationError{}} = load(%{}, "{not json")
    overlay = %{"p" => %{"format" => "xml", "path" => "/app/p.xml", "keySeparator" => ":"}}

    assert {:error, %DeclarationError{problems: ["overlay p: format must be json, yaml or toml"]}} =
             load(%{}, Map.put(@contract, "overlays", overlay))

    assert_raise DeclarationError, fn -> Contract.load!(Map.put(@contract, "kind", "X")) end
  end

  test "length limits on url, json and string list items" do
    contract =
      Map.put(@contract, "vars", %{
        "CALLBACK" => %{"type" => "url", "description" => "Callback URL", "maxLength" => 24},
        "LIMITS" => %{"type" => "json", "description" => "Run limits", "maxLength" => 16},
        "BRANCHES" => %{
          "type" => "list",
          "description" => "Branch codes",
          "items" => "string",
          "encoding" => "indexed",
          "itemMinLength" => 2,
          "itemMaxLength" => 4
        }
      })

    assert {:ok, values} =
             load(
               %{
                 "CALLBACK" => "https://例え.jp/日本語の道/一二三四",
                 "BRANCHES__0" => "ZÜ01",
                 "BRANCHES__1" => "日本"
               },
               contract
             )

    assert Values.to_map(values)["BRANCHES"] == ["ZÜ01", "日本"]

    r =
      load(
        %{
          "CALLBACK" => "https://a.example/runs/42",
          "LIMITS" => ~s|{ "max": 123456 }|,
          "BRANCHES__0" => "BE",
          "BRANCHES__1" => "GENEVA"
        },
        contract
      )

    assert Enum.sort(codes(r)) == [
             {"BRANCHES", :out_of_range},
             {"CALLBACK", :out_of_range},
             {"LIMITS", :out_of_range}
           ]

    bad =
      put_in(contract, ["vars", "PORTS"], %{
        "type" => "list",
        "description" => "Ports to open",
        "items" => "int",
        "itemMaxLength" => 5
      })

    assert {:error, %DeclarationError{problems: ps}} = load(%{}, bad)

    assert Enum.join(ps, "\n") =~
             "(PORTS): itemMinLength and itemMaxLength apply only to {:list, :string}"
  end

  describe "file inputs" do
    setup do
      root = Path.join(System.tmp_dir!(), "docuconf-cf-#{System.unique_integer([:positive])}")
      File.mkdir_p!(Path.join(root, "etc/orders/motd"))
      File.write!(Path.join(root, "etc/orders/motd/motd.txt"), "hello\n")
      on_exit(fn -> File.rm_rf!(root) end)

      contract =
        Map.put(@contract, "files", %{
          "motd" => %{
            "type" => "text",
            "description" => "Message of the day",
            "path" => "/etc/orders/motd/motd.txt",
            "required" => true,
            "reload" => "restart",
            "maxLength" => 10
          }
        })

      {:ok, root: root, contract: contract}
    end

    test "are checked and returned by name", %{root: root, contract: contract} do
      assert {:ok, %Values{values: %{"motd" => %Docuconf.LoadedFile{data: "hello\n"}}}} =
               load(%{"DOCUCONF_FILE_ROOT" => root}, contract)

      File.write!(Path.join(root, "etc/orders/motd/motd.txt"), "far too long\n")
      assert codes(load(%{"DOCUCONF_FILE_ROOT" => root}, contract)) == [{"motd", :out_of_range}]
    end

    test "reload watch is rejected", %{contract: contract} do
      contract = put_in(contract, ["files", "motd", "reload"], "watch")
      assert {:error, %DeclarationError{problems: [p]}} = load(%{}, contract)
      assert p =~ "reload \"watch\" is not supported"
    end
  end
end
