defmodule Docuconf.DocsTest do
  use ExUnit.Case, async: true

  alias Docuconf.{Contract, DeclarationError, Docs}

  defmodule Documented do
    use Docuconf, name: "documented"

    @doc """
    HTTP listen port.

    Behind the mesh, keep the default. See [`Plug.Cowboy`](`Plug.Cowboy`)
    and `m:Ingress` for the routing.
    """
    env :port, :integer, default: 8080, min: 1, max: 65535

    @doc """
    Cloud region for object storage.

    Change it together with the bucket:

    - `eu-west-1` for Europe
    - `us-east-1` for the US

    > #### Moving regions {: .warning}
    >
    > Buckets cannot move.

    ```elixir
    config :app, region: "us-east-1"
    ```
    """
    env :region, :string, default: "eu-west-1"

    @doc "Ignored: the explicit options win.\n\nAlso ignored."
    env :workers, :integer,
      description: "Worker processes",
      details: "One per *core*.",
      default: 4

    @doc "Token for the partner API."
    secret :token, :string

    env :plain, :string, description: "No details at all", default: "x"

    @doc """
    Licence key file.

    Issued per customer; rotate it yearly.
    """
    text_file :license, path: "/etc/app/license/license.key"

    # A function after the declarations keeps its own @doc.
    @doc "Not an input."
    def helper, do: :ok
  end

  defp var(name), do: Enum.find(Documented.__docuconf__().vars, &(&1.name == name))

  defp compile(body) do
    mod = "Docuconf.DocsTest.M#{System.unique_integer([:positive])}"

    Code.compile_string("""
    defmodule #{mod} do
      use Docuconf, name: "svc"
      #{body}
    end
    """)
  end

  defp problems(body) do
    e = assert_raise DeclarationError, fn -> compile(body) end
    Enum.join(e.problems, "\n")
  end

  test "the first paragraph of @doc is the description, the rest the details" do
    port = var("PORT")
    assert port.description == "HTTP listen port"

    assert port.details ==
             "Behind the mesh, keep the default. See `Plug.Cowboy`\nand `Ingress` for the routing."

    assert var("TOKEN").description == "Token for the partner API"
    assert var("TOKEN").details == nil
    assert var("PLAIN").details == nil
  end

  test "lists, code blocks and ExDoc admonitions become CommonMark" do
    assert var("REGION").details == """
           Change it together with the bucket:

           - `eu-west-1` for Europe
           - `us-east-1` for the US

           > #### Moving regions
           >
           > Buckets cannot move.

           ```elixir
           config :app, region: "us-east-1"
           ```\
           """
  end

  test "explicit options win over @doc" do
    assert var("WORKERS").description == "Worker processes"
    assert var("WORKERS").details == "One per *core*."
  end

  test "file inputs read @doc too" do
    [license] = Documented.__docuconf__().files
    assert license.description == "Licence key file"
    assert license.details == "Issued per customer; rotate it yearly."
    assert Documented.helper() == :ok
  end

  test "details come right after description in the contract" do
    out = Documented.export()

    assert out =~
             ~s(\t\tPORT: {\n\t\t\ttype: "int"\n\t\t\tdescription: "HTTP listen port"\n\t\t\tdetails: "Behind the mesh)
  end

  test "split and to_markdown" do
    assert Docs.split("One line.") == {"One line", ""}

    assert Docs.split("Wrapped\n  over lines.\n\nRest.\n\nMore.\n") ==
             {"Wrapped over lines", "Rest.\n\nMore."}

    assert Docs.split("  ") == {"", ""}

    assert Docs.to_markdown("Use `t:Mod.t/0` and [the helper](`Mod.fun/1`).") ==
             "Use `Mod.t/0` and `the helper`."

    assert Docs.to_markdown("```\n`m:kept`\n```") == "```\n`m:kept`\n```"
  end

  test "a missing description fails" do
    assert problems("env :nothing, :integer, default: 3") =~
             "description is required and must be at least 5 characters"
  end

  test "blank details fail" do
    assert problems(~s(env :blank, :string, description: "Has blank details", details: "  \\n ")) =~
             "details must not be blank"
  end

  test "details over 4000 code points fail" do
    long = String.duplicate("日本", 2000) <> "!"

    assert problems(
             ~s(env :long, :string, description: "Has long details", details: #{inspect(long)})
           ) =~
             "details are 4001 characters; at most 4000 are allowed"

    [{mod, _}] =
      compile(
        ~s(env :most, :string, description: "At the limit", details: #{inspect(String.duplicate("日本", 2000))})
      )

    assert [%{details: d}] = mod.__docuconf__().vars
    assert String.length(d) == 4000
  end

  test "details are never read at runtime" do
    [{mod, _}] =
      compile(
        ~s(@doc "HTTP listen port.\\n\\nKeep the default."\nenv :port, :integer, default: 8080)
      )

    assert {:ok, env} = Docuconf.load(mod, env: %{"PORT" => "9090"}, termination_log: false)
    assert env.port == 9090
    refute Map.has_key?(env, :details)
  end

  test "contract-first mode loads a contract with details, and checks them" do
    contract = %{
      "apiVersion" => "docuconf.dev/v1alpha1",
      "kind" => "ConfigContract",
      "metadata" => %{
        "name" => "svc",
        "generator" => %{"language" => "go", "sdk" => "x", "version" => "1"}
      },
      "vars" => %{
        "PORT" => %{
          "type" => "int",
          "description" => "HTTP listen port",
          "details" => "Keep it.\n\n- a\n- b",
          "default" => 8080
        }
      }
    }

    assert {:ok, values} = Contract.load(contract, env: %{"PORT" => "1"})
    assert values["PORT"] == 1

    blank = put_in(contract, ["vars", "PORT", "details"], " ")
    assert {:error, %DeclarationError{problems: ps}} = Contract.load(blank, env: %{})
    assert Enum.any?(ps, &(&1 =~ "details must not be blank"))
  end
end
