defmodule Docuconf.VarsTest do
  use ExUnit.Case, async: true

  defmodule Env do
    use Docuconf, name: "orders"

    env :port, :integer, description: "HTTP listen port", default: 4000, min: 1, max: 65535

    secret :database_url, :url,
      description: "Primary database",
      required: true,
      schemes: ["postgres", "ecto"]

    secret :api_token, :string, description: "Partner API token", min_length: 8, pattern: "^tok_"
    env :sample_rate, :float, description: "Trace sampling", default: 0.5, min: 0, max: 1
    env :debug, :boolean, description: "Verbose logging", default: false
    env :timeout, :duration, description: "Request timeout", default: "30s", min: "1s", max: "5m"
    env :poll, :duration, description: "Poll interval", unit: :duration, default: "1m30s"
    env :level, {:in, [:debug, :info]}, description: "Log level", default: :info
    env :origins, {:list, :string}, description: "CORS origins", min_items: 1, max_items: 2

    env :ports, {:list, :integer},
      description: "Worker ports",
      separator: ";",
      item_min: 1,
      item_max: 65535

    env :limits, :json,
      description: "Rate limits",
      schema: [per_minute: [type: :pos_integer, required: true]]

    env :region, :string, description: "Cloud region", pattern: "^[a-z]{2}-"
    env :motd, :string, description: "Message of the day"
    env :legacy, :string, description: "Old setting", deprecated: "use MOTD"
  end

  @base %{"DATABASE_URL" => "postgres://db/orders"}

  defp load(env), do: Env.load(env: Map.merge(@base, env), termination_log: false, warn: false)

  defp codes({:ok, _}), do: []

  defp codes({:error, %Docuconf.ValidationError{violations: vs}}),
    do: Enum.map(vs, &{&1.input, &1.code})

  test "typed values and defaults" do
    assert {:ok, env} = load(%{})
    assert %Env{port: 4000, sample_rate: 0.5, debug: false, timeout: 30_000, level: :info} = env
    assert env.poll == Duration.new!(second: 90)
    assert env.origins == nil
    assert env.motd == nil

    assert {:ok, env} =
             load(%{
               "PORT" => "8080",
               "SAMPLE_RATE" => "1e-1",
               "DEBUG" => "TRUE",
               "TIMEOUT" => "1m30s",
               "LEVEL" => "debug",
               "ORIGINS" => "https://a,https://b",
               "PORTS" => "1;2;3",
               "LIMITS" => ~s({"per_minute": 10}),
               "MOTD" => "",
               "API_TOKEN" => "tok_12345"
             })

    assert env.port == 8080
    assert env.sample_rate == 0.1
    assert env.debug == true
    assert env.timeout == 90_000
    assert env.origins == ["https://a", "https://b"]
    assert env.ports == [1, 2, 3]
    assert env.limits == %{per_minute: 10}
    # An empty string is a present value for strings only.
    assert env.motd == ""
  end

  test "empty string is unset for non-string types" do
    assert {:ok, %Env{port: 4000, debug: false}} = load(%{"PORT" => "", "DEBUG" => ""})

    assert codes(Env.load(env: %{"DATABASE_URL" => ""}, termination_log: false, warn: false)) ==
             [{"DATABASE_URL", :missing_required}]
  end

  test "every violation is reported together, with stable codes" do
    result =
      Env.load(
        env: %{
          "PORT" => "70000",
          "SAMPLE_RATE" => "NaN",
          "DEBUG" => "yes",
          "TIMEOUT" => "10m",
          "POLL" => "1500ns",
          "LEVEL" => "trace",
          "ORIGINS" => "a,b,c",
          "PORTS" => "1;x",
          "LIMITS" => ~s({"per_minute": 0}),
          "REGION" => "west",
          "API_TOKEN" => "short"
        },
        termination_log: false,
        warn: false
      )

    assert codes(result) == [
             {"API_TOKEN", :out_of_range},
             {"DATABASE_URL", :missing_required},
             {"DEBUG", :invalid_type},
             {"LEVEL", :not_in_enum},
             {"LIMITS", :schema_mismatch},
             {"ORIGINS", :too_many_items},
             {"POLL", :invalid_type},
             {"PORT", :out_of_range},
             {"PORTS", :invalid_type},
             {"REGION", :pattern_mismatch},
             {"SAMPLE_RATE", :invalid_type},
             {"TIMEOUT", :out_of_range}
           ]

    {:error, e} = result
    msg = Exception.message(e)
    assert msg =~ "docuconf: 12 configuration problems:"
    assert msg =~ "PORT [out_of_range]: \"70000\" is above max 65535"
  end

  test "bad int, bad url and invalid scheme" do
    assert codes(load(%{"PORT" => "80.5"})) == [{"PORT", :invalid_type}]
    # SPEC §5: outside the 64-bit range is out_of_range, not invalid_type.
    assert codes(load(%{"PORT" => "99999999999999999999"})) == [{"PORT", :out_of_range}]
    assert codes(load(%{"PORTS" => "1;9223372036854775808"})) == [{"PORTS", :out_of_range}]
    assert codes(load(%{"DATABASE_URL" => "not a url"})) == [{"DATABASE_URL", :invalid_type}]
    assert codes(load(%{"DATABASE_URL" => "mysql://db/x"})) == [{"DATABASE_URL", :invalid_scheme}]
    assert codes(load(%{"ORIGINS" => ""})) == []
  end

  test "secret values never appear in errors" do
    secret = "tok_SUPERSECRETVALUE"
    db = "mysql://admin:hunter2@db/x"

    {:error, e} =
      Env.load(
        env: %{"DATABASE_URL" => db, "API_TOKEN" => "SUPERSECRET"},
        termination_log: false,
        warn: false
      )

    msg = Exception.message(e)
    refute msg =~ "SUPERSECRET"
    refute msg =~ "hunter2"
    # The scheme is not the secret; the credentials and host are.
    assert msg =~ ~s(scheme "mysql" is not one of postgres, ecto)
    assert msg =~ "API_TOKEN [pattern_mismatch]"
    assert msg =~ "DATABASE_URL [invalid_scheme]"

    # Valid secrets load normally.
    assert {:ok, %Env{api_token: ^secret}} = load(%{"API_TOKEN" => secret})
  end

  test "list items outside item_min and item_max are out_of_range" do
    assert {:ok, %Env{ports: [1, 65535]}} = load(%{"PORTS" => "1;65535"})
    assert codes(load(%{"PORTS" => "80;0"})) == [{"PORTS", :out_of_range}]
    assert codes(load(%{"PORTS" => "65536"})) == [{"PORTS", :out_of_range}]
  end

  defmodule Lengths do
    use Docuconf, name: "ledger"

    env :callback, :url,
      description: "Where to report each run",
      schemes: ["https"],
      max_length: 24

    env :limits, :json, description: "Run limits as a JSON object", max_length: 16

    env :branches, {:list, :string},
      description: "Branch codes",
      item_min_length: 2,
      item_max_length: 4

    env :codes, {:list, :string},
      description: "Codes as JSON",
      encoding: :json,
      item_max_length: 4

    secret :db_url, :url, description: "Database connection string", max_length: 30
  end

  defp load_lengths(env), do: Lengths.load(env: env, termination_log: false, warn: false)

  defp messages({:error, %Docuconf.ValidationError{violations: vs}}),
    do: Enum.map_join(vs, "\n", & &1.message)

  test "maxLength on url and json, and item lengths, count code points" do
    assert {:ok, %Lengths{callback: "https://例え.jp/日本語の道/一二三四"}} =
             load_lengths(%{"CALLBACK" => "https://例え.jp/日本語の道/一二三四"})

    assert {:ok, %Lengths{limits: %{"n" => "日本語の道路xy"}}} =
             load_lengths(%{"LIMITS" => ~s|{"n":"日本語の道路xy"}|})

    # An emoji is 1 code point, 2 UTF-16 units.
    assert {:ok, %Lengths{branches: ["BE", "ZÜ01", "😀😀"], codes: ["😀😀😀😀"]}} =
             load_lengths(%{"BRANCHES" => "BE,ZÜ01,😀😀", "CODES" => ~s|["😀😀😀😀"]|})

    r =
      load_lengths(%{
        "CALLBACK" => "https://a.example/runs/42",
        "LIMITS" => ~s|{"max":123456789}|,
        "BRANCHES" => "BE,ZÜRICH",
        "CODES" => ~s|["BE","GENEVA"]|,
        "DB_URL" => "postgres://app:s3cr3t@db:5432/app"
      })

    assert Enum.sort(codes(r)) == [
             {"BRANCHES", :out_of_range},
             {"CALLBACK", :out_of_range},
             {"CODES", :out_of_range},
             {"DB_URL", :out_of_range},
             {"LIMITS", :out_of_range}
           ]

    text = messages(r)
    assert text =~ ~s|"https://a.example/runs/42" is 25 characters, longer than max_length 24|
    assert text =~ "is 17 characters of JSON, longer than max_length 16"
    assert text =~ ~s|item 2 ("ZÜRICH") is 6 characters, longer than item_max_length 4|
    # A secret reports its length, never its value.
    assert text =~ "value is 33 characters, longer than max_length 30"
    refute text =~ "s3cr3t"

    # Whitespace in a json value counts, as received.
    assert codes(load_lengths(%{"LIMITS" => ~s|{ "max": 123456 }|})) == [
             {"LIMITS", :out_of_range}
           ]

    assert codes(load_lengths(%{"BRANCHES" => "BE,B"})) == [{"BRANCHES", :out_of_range}]
  end

  defmodule Encoded do
    use Docuconf, name: "encoded"

    env :brokers, {:list, :string}, description: "Kafka brokers", encoding: :indexed
    env :shards, {:list, :integer}, description: "Shard ids", encoding: :json, item_max: 9
    env :grace, :duration, description: "Shutdown grace", encoding: :iso8601
    env :ttl, :duration, description: "Cache TTL", encoding: :seconds, unit: :second
    env :window, :duration, description: "Rate window", encoding: :timespan
  end

  test "declared list and duration encodings are parsed" do
    env = %{
      "BROKERS__0" => "kafka-0:9092",
      "BROKERS__1" => "kafka-1:9092",
      "SHARDS" => "[1,2]",
      "GRACE" => "PT1.5S",
      "TTL" => "90",
      "WINDOW" => "00:01:00"
    }

    assert {:ok, %Encoded{} = e} = Encoded.load(env: env, termination_log: false, warn: false)
    assert e.brokers == ["kafka-0:9092", "kafka-1:9092"]
    assert e.shards == [1, 2]
    assert {e.grace, e.ttl, e.window} == {1500, 90, 60_000}

    bad = %{"SHARDS" => "[1,10]", "GRACE" => "1s", "TTL" => "1m", "WINDOW" => "1m"}

    assert {:error, %{violations: vs}} =
             Encoded.load(env: bad, termination_log: false, warn: false)

    assert Enum.map(vs, &{&1.input, &1.code}) == [
             {"GRACE", :invalid_type},
             {"SHARDS", :out_of_range},
             {"TTL", :invalid_type},
             {"WINDOW", :invalid_type}
           ]
  end

  test "indexed lists start at 0, have no gap, and ignore non-numeric suffixes" do
    load = &Encoded.load(env: &1, termination_log: false, warn: false)

    assert {:ok, %Encoded{brokers: ["a"]}} =
             load.(%{"BROKERS__0" => "a", "BROKERS__HOST" => "x", "BROKERS__01" => "y"})

    for env <- [
          %{"BROKERS__0" => "a", "BROKERS__2" => "c"},
          %{"BROKERS__1" => "b"}
        ] do
      assert {:error, %{violations: [v]}} = load.(env)
      assert {v.input, v.code} == {"BROKERS", :invalid_type}
      assert v.message =~ "no gap"
    end

    assert {:error, %{violations: [v]}} = load.(%{"BROKERS__0" => "a", "BROKERS__2" => "c"})
    assert v.message =~ "no BROKERS__1"
  end

  test "values are never trimmed" do
    assert codes(load(%{"PORT" => "8080\n"})) == [{"PORT", :invalid_type}]
    assert {:ok, %Env{motd: " hi \n"}} = load(%{"MOTD" => " hi \n"})
  end

  test "load! raises with every problem, and writes the termination log" do
    dir = Path.join(System.tmp_dir!(), "docuconf-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    log = Path.join(dir, "termination-log")

    e =
      assert_raise Docuconf.ValidationError, fn ->
        Env.load!(
          env: %{"PORT" => "x", "API_TOKEN" => "nope-secret"},
          termination_log: log,
          warn: false
        )
      end

    assert length(e.violations) == 3
    written = File.read!(log)
    assert written =~ "PORT [invalid_type]"
    assert written =~ "DATABASE_URL [missing_required]"
    refute written =~ "nope-secret"
  end

  test "a secret holding an unresolved injector reference fails without printing it" do
    dir = Path.join(System.tmp_dir!(), "docuconf-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    log = Path.join(dir, "termination-log")

    refs = %{
      "DATABASE_URL" => "vault:secret/data/orders#database_url",
      "API_TOKEN" => "op://prod/partner/token"
    }

    assert {:error, e} = Env.load(env: refs, termination_log: log, warn: false)

    assert Enum.map(e.violations, &{&1.input, &1.code, &1.message}) == [
             {"API_TOKEN", :invalid_type,
              "holds an unresolved op:// reference; the injector that should resolve it did not run"},
             {"DATABASE_URL", :invalid_type,
              "holds an unresolved vault: reference; the injector that should resolve it did not run"}
           ]

    written = File.read!(log)
    assert written =~ "DATABASE_URL [invalid_type]: holds an unresolved vault: reference"

    for {_, value} <- refs do
      refute Exception.message(e) =~ value
      refute written =~ value
      refute inspect(e) =~ value
    end

    assert codes(load(%{"API_TOKEN" => "ref+awsssm://prod/token"})) == [
             {"API_TOKEN", :invalid_type}
           ]

    # Only a prefix counts, and only on secrets.
    assert {:ok, %Env{api_token: "tok_vault:x"}} = load(%{"API_TOKEN" => "tok_vault:x"})
    assert {:ok, %Env{motd: "vault:not-a-secret"}} = load(%{"MOTD" => "vault:not-a-secret"})
  end

  test "deprecated variables and secrets ending in a newline warn" do
    out =
      ExUnit.CaptureIO.capture_io(:stderr, fn ->
        Env.load(
          env: Map.merge(@base, %{"LEGACY" => "x", "API_TOKEN" => "tok_123456\n"}),
          termination_log: false
        )
      end)

    assert out =~ "LEGACY is deprecated: use MOTD"
    assert out =~ "API_TOKEN ends with a newline"
    refute out =~ "tok_123456"
  end

  test "a .env file is opt-in and real variables win" do
    path = Path.join(System.tmp_dir!(), "docuconf-#{System.unique_integer([:positive])}.env")
    File.write!(path, "# dev\nexport PORT=5000\nMOTD=\"hello\\nworld\"\nREGION='eu-west'\n")

    assert {:ok, env} =
             Env.load(
               env: Map.merge(@base, %{"REGION" => "us-east"}),
               dotenv: path,
               termination_log: false,
               warn: false
             )

    assert env.port == 5000
    assert env.motd == "hello\nworld"
    assert env.region == "us-east"
  end
end
