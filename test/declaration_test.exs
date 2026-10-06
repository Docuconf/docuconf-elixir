defmodule Docuconf.DeclarationTest do
  use ExUnit.Case, async: true

  defp compile(body, name \\ "svc") do
    mod = "Docuconf.DeclarationTest.M#{System.unique_integer([:positive])}"

    Code.compile_string("""
    defmodule #{mod} do
      use Docuconf, name: #{inspect(name)}
      #{body}
    end
    """)
  end

  defp problems(body, name \\ "svc") do
    e = assert_raise Docuconf.DeclarationError, fn -> compile(body, name) end
    e.problems
  end

  test "a valid declaration compiles and builds a struct" do
    [{mod, _}] = compile(~s|env :port, :integer, description: "HTTP listen port", default: 4000|)
    assert %{__struct__: ^mod, port: nil} = struct(mod)
  end

  test "every problem is reported together" do
    ps =
      problems(
        """
        env :port, :integer, description: "port"
        env :timeout, :duration, description: "Request timeout", default: "soon"
        env :level, {:in, ["a"]}, description: "Log level", default: "b"
        env :token, :string, description: "API token", secret: true, default: "x"
        env :name, :string, description: "A name here", required: true, default: "x"
        env :host, :string, description: "Host name", pattern: "a(?=b)"
        env :count, :integer, description: "A count", min: 5, max: 1
        env :size, :integer, description: "A size", min: 10, default: 3
        env :weird, :uuid, description: "Unknown type"
        env :typo, :string, description: "Option typo", min_lenght: 3
        """,
        "Bad_Name"
      )

    text = Enum.join(ps, "\n")
    assert text =~ "name \"Bad_Name\" must be a DNS label"
    assert text =~ "PORT): description is required and must be at least 5 characters"
    assert text =~ "TIMEOUT): default \"soon\" is not a Go duration"
    assert text =~ "LEVEL): default does not satisfy"
    assert text =~ "TOKEN): a secret must not have a default"
    assert text =~ "NAME): a required variable must not have a default"
    assert text =~ "HOST): pattern \"a(?=b)\" uses lookahead"
    assert text =~ "COUNT): min is greater than max"
    assert text =~ "SIZE): default does not satisfy the variable's constraints (out_of_range"
    assert text =~ "unknown type :uuid"
    assert text =~ "unknown options [:min_lenght]"
  end

  test "item bounds apply to integer lists only, and must be ordered" do
    text =
      Enum.join(
        problems("""
        env :tags, {:list, :string}, description: "Tags to apply", item_max: 3
        env :shards, {:list, :integer}, description: "Shard ids", item_min: 10, item_max: 1
        env :ports, {:list, :integer}, description: "Port list", item_min: 1.5
        env :ids, {:list, :integer}, description: "Some ids", item_max: 9, default: [1, 10]
        """),
        "\n"
      )

    assert text =~ "TAGS): item_min and item_max apply only to {:list, :integer}"
    assert text =~ "SHARDS): item_min is greater than item_max"
    assert text =~ "PORTS): item_min and item_max must be integers"
    assert text =~ "IDS): default does not satisfy the variable's constraints (out_of_range"
  end

  test "names must be upper snake case" do
    assert Enum.join(problems(~s|env :port, :integer, description: "Listen port", name: "port"|)) =~
             "name must match"
  end

  test "file inputs are checked" do
    ps =
      problems("""
      env :password, :string, description: "Not a secret"
      env :cert_path, :string, description: "Where the cert is"
      tls_file :tls, description: "Serving cert", path: "/etc/svc/tls", key_algorithms: [:dsa]
      text_file :a, description: "First file", path: "/etc/svc/conf/a.txt"
      text_file :b, description: "Second file", path: "/etc/svc/conf/b.txt", path_env: "CERT_PATH"
      ca_bundle_file :c, description: "CA bundle", path: "/etc/ssl/certs/private.pem"
      keystore_file :ks, description: "A keystore", format: :pkcs12, path: "/etc/svc/ks/ks.p12", password_var: :password
      config_file :cfg, description: "A config", format: :yaml, path: "/etc/svc/cfg/c.yaml"
      binary_file :Bad, description: "Bad name", path: "relative/path"
      """)

    text = Enum.join(ps, "\n")
    assert text =~ "key_algorithms must be"
    assert text =~ "share mount directory /etc/svc/conf"
    assert text =~ "path_env CERT_PATH must not also be declared"
    assert text =~ "reserved directory /etc/ssl/certs"
    assert text =~ "password_var PASSWORD must name a declared secret variable"
    assert text =~ "format yaml needs decoder"
    assert text =~ "input name must be a DNS label"
    assert text =~ "path must be absolute"
  end

  test "feature-flag-looking names warn at compile time" do
    output =
      ExUnit.CaptureIO.capture_io(:stderr, fn ->
        compile(
          ~s|env :enable_checkout, :boolean, description: "New checkout flow", default: false|
        )
      end)

    assert output =~ "ENABLE_CHECKOUT looks like a feature flag"

    quiet =
      ExUnit.CaptureIO.capture_io(:stderr, fn ->
        compile(
          ~s|env :ff_kill, :boolean, description: "Kill switch", default: false, flag_warning: false|
        )
      end)

    refute quiet =~ "feature flag"
  end
end
