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
    env :ports, {:list, :integer}, description: "Worker ports", separator: ";"

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
    assert %Env{port: 4000, sample_rate: 0.5, debug: false, timeout: 30_000, level: "info"} = env
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
    assert codes(load(%{"PORT" => "99999999999999999999"})) == [{"PORT", :invalid_type}]
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
    refute msg =~ "mysql"
    assert msg =~ "API_TOKEN [pattern_mismatch]"
    assert msg =~ "DATABASE_URL [invalid_scheme]"

    # Valid secrets load normally.
    assert {:ok, %Env{api_token: ^secret}} = load(%{"API_TOKEN" => secret})
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
