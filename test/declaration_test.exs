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
    assert text =~ "unknown option :min_lenght for :string; did you mean :min_length?"
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

  test "length limits apply to the right types, must be ordered and hold the default" do
    text =
      Enum.join(
        problems("""
        env :ports, {:list, :integer}, description: "Ports to open", item_max_length: 5
        env :flag, :boolean, description: "A boolean flag", max_length: 5
        env :name, :string, description: "A plain name", item_min_length: 1
        env :codes, {:list, :string}, description: "Branch codes", item_min_length: 5, item_max_length: 4
        env :neg, :url, description: "Negative limit", max_length: -1
        env :site, :url, description: "Default too long", max_length: 10, default: "https://example.com"
        env :branches, {:list, :string}, description: "Default item", item_max_length: 4, default: ["BE", "ZÜRICH"]
        env :regions, {:list, :string}, description: "Default item", item_min_length: 2, default: ["B"]
        env :limits, :json, description: "Default JSON", max_length: 16, default: %{"max" => 123_456_789}
        """),
        "\n"
      )

    assert text =~ "PORTS): item_min_length and item_max_length apply only to {:list, :string}"
    assert text =~ "unknown option :max_length for :boolean"
    assert text =~ "unknown option :item_min_length for :string"
    assert text =~ "CODES): item_min_length is greater than item_max_length"
    assert text =~ "NEG): lengths must be non-negative integers"

    assert text =~
             ~s|SITE): default does not satisfy the variable's constraints (out_of_range: "https://example.com" is 19 characters, longer than max_length 10)|

    assert text =~
             ~s|BRANCHES): default does not satisfy the variable's constraints (out_of_range: item 2 ("ZÜRICH") is 6 characters, longer than item_max_length 4)|

    assert text =~
             ~s|REGIONS): default does not satisfy the variable's constraints (out_of_range: item 1 ("B") is 1 characters, shorter than item_min_length 2)|

    # The compact JSON {"max":123456789} is 17 characters.
    assert text =~
             "LIMITS): default does not satisfy the variable's constraints (out_of_range: is 17 characters of JSON, longer than max_length 16)"
  end

  test "defaults at the limits, counted in code points, compile" do
    # 24 characters but more bytes; an emoji is 1 code point (2 UTF-16
    # units); {"a":"<&>"} is 11 characters, with no HTML escaping.
    compile("""
    env :site, :url, description: "Default at the limit", max_length: 24, default: "https://例え.jp/日本語の道/一二三四"
    env :branches, {:list, :string}, description: "Branch codes", item_max_length: 4, default: ["ZÜ01", "日本", "😀😀😀😀"]
    env :limits, :json, description: "Run limits", max_length: 11, default: %{"a" => "<&>"}
    """)
  end

  test "encodings are checked" do
    text =
      Enum.join(
        problems("""
        env :a, {:list, :string}, description: "Some list", encoding: :yaml
        env :b, {:list, :string}, description: "Some list", encoding: :json, separator: ";"
        env :c, :duration, description: "Some duration", encoding: :weeks
        env :d, :string, description: "Some string", encoding: :json
        """),
        "\n"
      )

    assert text =~ "(A): encoding must be :csv, :json or :indexed"
    assert text =~ "(B): separator applies only to the csv encoding"
    assert text =~ "(C): encoding must be :go, :iso8601, :seconds or :timespan"

    assert text =~
             "env :d: unknown option :encoding for :string; :encoding does not apply to type :string"
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

  describe "diagnostics point at the declaration" do
    @tag :tmp_dir
    test "each problem carries its file:line, and the stacktrace the first one", %{tmp_dir: dir} do
      path = Path.join(dir, "bad.ex")

      File.write!(path, """
      defmodule Docuconf.DeclarationTest.Lines do
        use Docuconf, name: "svc"

        env :port, :integer, description: "HTTP listen port", maximum: 10
        env :workers, :pos_intger, description: "Worker count"
      end
      """)

      {e, stack} =
        try do
          Code.compile_file(path)
        rescue
          e in Docuconf.DeclarationError -> {e, __STACKTRACE__}
        end

      file = Path.relative_to_cwd(path)
      message = Exception.message(e)

      assert message =~
               "#{file}:4: env :port: unknown option :maximum for :integer; did you mean :max?"

      assert message =~
               "#{file}:5: env :workers: unknown type :pos_intger (did you mean :pos_integer?)"

      assert [{Docuconf.DeclarationTest.Lines, :__MODULE__, 0, loc} | _] = stack
      assert loc[:line] == 4
    end

    test "the feature-flag warning names its line and the fix" do
      warning =
        ExUnit.CaptureIO.capture_io(:stderr, fn ->
          compile("""

          env :enable_beta, :boolean, description: "Beta checkout", default: false
          """)
        end)

      assert warning =~ "ENABLE_BETA looks like a feature flag"
      assert warning =~ "flag_warning: false"
      assert warning =~ "nofile:4"
    end
  end

  test "declaring without use Docuconf is a compile error, not a no-op" do
    e =
      assert_raise CompileError, fn ->
        Code.compile_string("""
        defmodule Docuconf.DeclarationTest.NoUse do
          import Docuconf
          env :port, :integer, description: "HTTP listen port"
        end
        """)
      end

    assert Exception.message(e) =~ "must be called inside a module that has use Docuconf"
  end

  test "NimbleOptions integer types are sugar for a lower bound" do
    [{mod, _}] =
      compile("""
      env :workers, :pos_integer, description: "Worker count", default: 4
      env :retries, :non_neg_integer, description: "Retry count", default: 0
      """)

    [retries, workers] = mod.__docuconf__().vars
    assert {workers.type, workers.min} == {"int", 1}
    assert {retries.type, retries.min} == {"int", 0}

    assert {:error, e} = mod.load(env: %{"WORKERS" => "0"}, termination_log: false)
    assert Exception.message(e) =~ "WORKERS [out_of_range]"
  end

  test "duration defaults accept integers in the unit and Elixir Durations" do
    [{mod, _}] =
      compile("""
      env :timeout, :duration, description: "Request timeout", default: 30_000
      env :poll, :duration, description: "Poll interval", unit: :second, default: 90, max: 600
      env :grace, :duration, description: "Shutdown grace", default: Duration.new!(minute: 1)
      env :ttl, :duration, description: "Cache TTL", encoding: :iso8601, default: "PT1H"
      """)

    {:ok, env} = mod.load(env: %{}, termination_log: false)
    assert env.timeout == 30_000
    assert env.poll == 90
    assert env.grace == 60_000
    assert env.ttl == 3_600_000
    assert mod.export() =~ ~s(default: "30s")

    text =
      Enum.join(
        problems("""
        env :a, :duration, description: "Some duration", unit: :duration, default: 5
        env :b, :duration, description: "Some duration", default: Duration.new!(month: 1)
        """),
        "\n"
      )

    assert text =~ "default 5 has no unit here"
    assert text =~ "uses years or months"
  end

  test "an ISO 8601 duration given Go syntax shows the expected form" do
    [{mod, _}] =
      compile(~s|env :ttl, :duration, description: "Cache TTL", encoding: :iso8601|)

    {:error, e} = mod.load(env: %{"TTL" => "30s"}, termination_log: false)

    assert Exception.message(e) =~
             ~s(TTL [invalid_type]: "30s" is not an ISO 8601 duration such as PT1M30S; write PT30S)
  end

  test "boolean options must be booleans" do
    [p] = problems(~s|env :port, :integer, description: "HTTP listen port", required: "yes"|)
    assert p =~ ~s(required must be true or false, got "yes")
  end

  test "messages use the DSL's option names" do
    [{mod, _}] =
      compile(~s|env :key, :string, description: "Signing key", min_length: 64|)

    {:error, e} = mod.load(env: %{"KEY" => "short"}, termination_log: false)
    assert Exception.message(e) =~ "shorter than min_length 64"

    [p] =
      problems(~s|env :key, :string, description: "Signing key", min_length: 9, max_length: 2|)

    assert p =~ "min_length is greater than max_length"
  end
end
