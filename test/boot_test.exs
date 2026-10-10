defmodule Docuconf.BootTest do
  # What a first-time user meets at boot: redaction, clean failures, the
  # environment sources, typo hints and the generated types.
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias Docuconf.Test.SecretEnv

  @secret_key "S3CR3T" <> String.duplicate("s", 58)
  @db "postgres://orders:hunter2@db.internal/orders"

  defp root_with_license(dir) do
    File.mkdir_p!(Path.join(dir, "etc/secrets/license"))
    File.write!(Path.join(dir, "etc/secrets/license/license.key"), "LICENSE-CONTENT-42")
    dir
  end

  defp load_secret_env(dir, extra \\ %{}) do
    env =
      Map.merge(
        %{"SECRET_KEY_BASE" => @secret_key, "DATABASE_URL" => @db},
        extra
      )

    SecretEnv.load!(env: env, file_root: root_with_license(dir), termination_log: false)
  end

  describe "secrets are redacted when inspected" do
    @describetag :tmp_dir

    test "inspect, Logger and the LoadedFile", %{tmp_dir: dir} do
      env = load_secret_env(dir)
      assert env.secret_key_base == @secret_key
      assert env.license.data == "LICENSE-CONTENT-42"

      for shown <- [
            inspect(env),
            inspect(env, pretty: true, limit: :infinity),
            inspect(env.license)
          ] do
        refute shown =~ "S3CR3T"
        refute shown =~ "hunter2"
        refute shown =~ "LICENSE-CONTENT"
      end

      shown = inspect(env)
      assert shown =~ "#Docuconf.Test.SecretEnv<"
      assert shown =~ "secret_key_base: **redacted**"
      assert shown =~ "database_url: **redacted**"
      assert shown =~ "port: 4000"
      assert shown =~ "log_level: :info"

      logged =
        ExUnit.CaptureLog.capture_log(fn ->
          require Logger
          Logger.error("config: #{inspect(env)}")
        end)

      refute logged =~ "S3CR3T"
    end

    test "an unset secret shows as nil", %{tmp_dir: dir} do
      env =
        SecretEnv.load!(
          env: %{"SECRET_KEY_BASE" => @secret_key},
          file_root: root_with_license(dir),
          termination_log: false
        )

      assert inspect(env) =~ "database_url: nil"
    end

    test "the watcher's state is not shown with its environment" do
      state = %{env: %{"SECRET_KEY_BASE" => @secret_key}, interval: 5}
      status = Docuconf.Watcher.format_status(%{state: state})
      refute inspect(status) =~ "S3CR3T"

      # The parsed variables (keystore passwords) too.
      state = Map.put(state, :vars, %{"SECRET_KEY_BASE" => @secret_key})
      status = Docuconf.Watcher.format_status(%{state: state})
      refute inspect(status) =~ "S3CR3T"
    end
  end

  defmodule LeakyDecoder do
    # A user-written decoder whose error repeats the input.
    def decode(content), do: {:error, "unexpected token in: " <> content}
    def raise!(content), do: raise("cannot parse " <> content)
  end

  defmodule SecretConfig do
    use Docuconf, name: "secret-config"

    config_file :creds,
      format: :yaml,
      decoder: &LeakyDecoder.decode/1,
      secret: true,
      required: true,
      description: "Partner credentials",
      path: "/etc/creds/creds.yaml"

    config_file :more,
      format: :toml,
      decoder: &LeakyDecoder.raise!/1,
      secret: true,
      required: true,
      description: "More credentials",
      path: "/etc/more/more.toml"
  end

  @tag :tmp_dir
  test "a user decoder's error never carries a secret file's content", %{tmp_dir: dir} do
    for {sub, file} <- [{"etc/creds", "creds.yaml"}, {"etc/more", "more.toml"}] do
      File.mkdir_p!(Path.join(dir, sub))
      File.write!(Path.join([dir, sub, file]), "password: TOPSECRET99")
    end

    {:error, e} = SecretConfig.load(env: %{}, file_root: dir)
    message = Exception.message(e)
    assert message =~ "creds [file_malformed]"
    assert message =~ "more [file_malformed]"
    refute message =~ "TOPSECRET99"
  end

  describe "generated types and docs" do
    test "@type t describes every field" do
      {:ok, [{:type, t}]} = Code.Typespec.fetch_types(SecretEnv)
      text = t |> Code.Typespec.type_to_quoted() |> Macro.to_string()
      assert text =~ "port: pos_integer()"
      assert text =~ "log_level: :debug | :info | :warning"
      assert text =~ "secret_key_base: String.t()"
      assert text =~ "database_url: String.t() | nil"
      assert text =~ "license: Docuconf.LoadedFile.t() | nil"
    end

    test "a moduledoc lists the variables" do
      {:docs_v1, _, _, _, %{"en" => doc}, _, _} = Code.fetch_docs(SecretEnv)
      assert doc =~ "| `PORT` | int | `4000` | HTTP listen port |"
      assert doc =~ "| `SECRET_KEY_BASE` | string | secret | Cookie signing key |"
      assert doc =~ "| `license` | text |"
    end

    @tag :tmp_dir
    test "atom enums come back as atoms", %{tmp_dir: dir} do
      assert load_secret_env(dir).log_level == :info
      assert load_secret_env(dir, %{"LOG_LEVEL" => "warning"}).log_level == :warning
    end
  end

  describe "the environment a load reads" do
    @describetag :tmp_dir

    test "dotenv: false and nil read no file", %{tmp_dir: dir} do
      # What dotenv: config_env() == :dev && ".env" gives outside dev.
      for off <- [false, nil] do
        assert %SecretEnv{port: 4000} =
                 SecretEnv.load!(
                   env: %{"SECRET_KEY_BASE" => @secret_key},
                   dotenv: off,
                   file_root: dir,
                   termination_log: false
                 )
      end
    end

    test "a dotenv that is not a path, nil or false is an ArgumentError", %{tmp_dir: dir} do
      assert_raise ArgumentError, ~r/:dotenv must be a path, nil or false/, fn ->
        SecretEnv.load(env: %{}, dotenv: :yes, file_root: dir)
      end
    end

    test "a missing dotenv file is a warning", %{tmp_dir: dir} do
      err =
        capture_io(:stderr, fn ->
          SecretEnv.load(
            env: %{"SECRET_KEY_BASE" => @secret_key},
            dotenv: Path.join(dir, ".env.missing"),
            file_root: dir,
            termination_log: false
          )
        end)

      assert err =~ "docuconf: warning: dotenv file #{dir}/.env.missing does not exist"
    end

    test "fallback_env fills only what nothing else sets", %{tmp_dir: dir} do
      File.write!(Path.join(dir, ".env"), "PORT=5000\n")

      env =
        SecretEnv.load!(
          env: %{"LOG_LEVEL" => "debug"},
          dotenv: Path.join(dir, ".env"),
          fallback_env: %{
            "SECRET_KEY_BASE" => @secret_key,
            "PORT" => "1",
            "LOG_LEVEL" => "warning"
          },
          file_root: dir,
          termination_log: false
        )

      assert env.secret_key_base == @secret_key
      assert env.port == 5000
      assert env.log_level == :debug

      assert_raise ArgumentError, ~r/:fallback_env must be a map/, fn ->
        SecretEnv.load(env: %{}, fallback_env: "SECRET_KEY_BASE=x", file_root: dir)
      end
    end

    test "a set variable one edit from a declared name gets a hint", %{tmp_dir: dir} do
      err =
        capture_io(:stderr, fn ->
          load_secret_env(dir, %{
            "DATABSE_URL" => "postgres://typo-secret@db/x",
            "PROT" => "8080",
            # Unrelated names stay quiet, including short ones two edits away.
            "HOST" => "x",
            "PATH" => "/usr/bin",
            "SECRET_KEY_BASE_FILE" => "/x"
          })
        end)

      assert err =~
               "docuconf: warning: DATABSE_URL is set but not declared; did you mean DATABASE_URL?"

      assert err =~ "PROT is set but not declared; did you mean PORT?"
      refute err =~ "HOST"
      refute err =~ "PATH"
      refute err =~ "SECRET_KEY_BASE_FILE"
      refute err =~ "typo-secret"
    end

    test "a missing file mentions DOCUCONF_FILE_ROOT when no root is set" do
      mod = Module.concat(__MODULE__, "Required#{System.unique_integer([:positive])}")

      Code.compile_string("""
      defmodule #{inspect(mod)} do
        use Docuconf, name: "svc"
        text_file :motd, description: "Message of the day", required: true,
          path: "/etc/svc-#{System.unique_integer([:positive])}/motd.txt"
      end
      """)

      {:error, e} = mod.load(env: %{}, termination_log: false)
      assert Exception.message(e) =~ "set DOCUCONF_FILE_ROOT to read it under a local directory"
    end
  end

  describe "load! at boot" do
    @describetag :tmp_dir

    test "with env: it raises", %{tmp_dir: dir} do
      assert_raise Docuconf.ValidationError, ~r/SECRET_KEY_BASE \[missing_required\]/, fn ->
        SecretEnv.load!(env: %{}, file_root: dir, termination_log: false)
      end

      assert_raise ArgumentError, ~r/:on_error must be :halt or :raise/, fn ->
        SecretEnv.load!(env: %{}, on_error: :explode)
      end
    end

    test "from the process environment it prints the problems and exits 1", %{tmp_dir: dir} do
      log = Path.join(dir, "termination-log")

      script = """
      defmodule Boot.Env do
        use Docuconf, name: "boot"
        env :port, :integer, description: "HTTP listen port", min: 1
        secret :database_url, :url, description: "Primary database", required: true, schemes: ["postgres"]
      end
      Boot.Env.load!()
      IO.puts("still running")
      """

      {out, status} =
        System.cmd(
          System.find_executable("elixir"),
          ["-pa", Path.join(:code.lib_dir(:docuconf), "ebin"), "-e", script],
          env: [
            {"DOCUCONF_TERMINATION_LOG", log},
            {"PORT", "0"},
            {"DATABASE_URL", "mysql://admin:hunter2@db/x"}
          ],
          stderr_to_stdout: true,
          cd: dir
        )

      assert status == 1

      assert out ==
               """
               docuconf: 2 configuration problems:
                 - DATABASE_URL [invalid_scheme]: scheme "mysql" is not one of postgres
                 - PORT [out_of_range]: "0" is below min 1
               """

      assert File.read!(log) == String.trim_trailing(out)
      refute File.exists?(Path.join(dir, "erl_crash.dump"))
    end
  end
end
