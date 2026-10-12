defmodule Docuconf.WatcherTest do
  use ExUnit.Case, async: true

  defmodule Env do
    use Docuconf, name: "watched"

    config_file :routes,
      format: :json,
      description: "Routing table",
      path: "/etc/svc/routes/routes.json",
      reload: :watch,
      schema: [routes: [type: {:list, :string}, required: true]]

    text_file :motd, description: "Message of the day", path: "/etc/svc/motd/motd.txt"
  end

  setup do
    root = Path.join(System.tmp_dir!(), "docuconf-watch-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(root) end)
    File.mkdir_p!(Path.join(root, "etc/svc/routes"))
    File.mkdir_p!(Path.join(root, "etc/svc/motd"))
    File.write!(Path.join(root, "etc/svc/routes/routes.json"), ~s({"routes": ["/a"]}))
    File.write!(Path.join(root, "etc/svc/motd/motd.txt"), "hello")
    {:ok, root: root}
  end

  test "reports valid changes to watched files and rejects invalid ones", %{root: root} do
    test = self()

    start_supervised!(
      {Docuconf.Watcher,
       module: Env,
       env: %{"DOCUCONF_FILE_ROOT" => root},
       interval: 20,
       on_change: fn field, file -> send(test, {:changed, field, file.data}) end,
       on_error: fn field, vs -> send(test, {:invalid, field, Enum.map(vs, & &1.code)}) end}
    )

    # Kubernetes-style atomic update: write elsewhere, then rename over.
    tmp = Path.join(root, "etc/svc/routes/.new")
    File.write!(tmp, ~s({"routes": ["/a", "/b"]}))
    File.rename!(tmp, Path.join(root, "etc/svc/routes/routes.json"))
    assert_receive {:changed, :routes, %{routes: ["/a", "/b"]}}, 1_000

    File.write!(Path.join(root, "etc/svc/routes/routes.json"), ~s({"routes": "nope"}))
    assert_receive {:invalid, :routes, [:schema_mismatch]}, 1_000

    # motd is reload: restart, so it is not watched.
    File.write!(Path.join(root, "etc/svc/motd/motd.txt"), "changed")
    refute_receive {:changed, :motd, _}, 200
  end

  defmodule DotenvEnv do
    use Docuconf, name: "watched-dotenv"

    config_file :routes,
      format: :json,
      description: "Routing table",
      path: "/etc/svc/routes/routes.json",
      reload: :watch
  end

  test "the watcher reads the environment the way load did, .env included", %{root: root} do
    dotenv = Path.join(root, ".env")
    File.write!(dotenv, "DOCUCONF_FILE_ROOT=#{root}\n")

    assert {:ok, %{routes: %{data: %{"routes" => ["/a"]}}}} =
             DotenvEnv.load(dotenv: dotenv, watcher_check: false, termination_log: false)

    test = self()

    start_supervised!(
      {Docuconf.Watcher,
       module: DotenvEnv,
       interval: 20,
       on_change: fn field, file -> send(test, {:changed, field, file.data}) end}
    )

    File.write!(Path.join(root, "etc/svc/routes/routes.json"), ~s({"routes": ["/c"]}))
    assert_receive {:changed, :routes, %{"routes" => ["/c"]}}, 1_000
  end
end

defmodule Docuconf.WatcherHooksTest do
  # Hooks, the current value and the reload status (SPEC §4.6.2).
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Docuconf.{LoadedFile, RejectedReload, ReloadStatus, Watcher}
  alias Docuconf.Test.Certs

  defmodule Routes do
    use Docuconf, name: "watched-hooks"

    config_file :routes,
      format: :json,
      description: "Routing table",
      path: "/etc/svc/routes/routes.json",
      reload: :watch,
      secret: true,
      schema: [routes: [type: {:list, :string}, required: true]]

    text_file :motd, description: "Message of the day", path: "/etc/svc/motd/motd.txt"
  end

  defmodule Thrower do
    use Docuconf, name: "watched-thrower"

    text_file :motd,
      description: "Message of the day",
      path: "/etc/svc/motd/motd.txt",
      reload: :watch
  end

  defmodule Keystore do
    use Docuconf, name: "watched-keystore"

    secret :ks_password, :string, description: "Keystore password"

    keystore_file :partner,
      format: :pkcs12,
      description: "Partner client certificate",
      path: "/etc/svc/partner/ks.p12",
      password_var: :ks_password,
      reload: :watch
  end

  setup do
    root = Path.join(System.tmp_dir!(), "docuconf-hooks-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(root) end)
    File.mkdir_p!(Path.join(root, "etc/svc/routes"))
    File.mkdir_p!(Path.join(root, "etc/svc/motd"))
    File.write!(Path.join(root, "etc/svc/routes/routes.json"), ~s({"routes": ["/a"]}))
    File.write!(Path.join(root, "etc/svc/motd/motd.txt"), "hello")
    {:ok, root: root}
  end

  defp put(root, rel, content) do
    tmp = Path.join(root, rel <> ".new")
    File.write!(tmp, content)
    File.rename!(tmp, Path.join(root, rel))
  end

  defp start(module, root, opts \\ []) do
    start_supervised!(
      {Watcher,
       [
         module: module,
         env: %{"DOCUCONF_FILE_ROOT" => root},
         interval: 20,
         on_error: fn _, _ -> :ok end
       ] ++
         opts}
    )
  end

  test "hooks fire after an accepted change, never after a rejected one", %{root: root} do
    start(Routes, root)
    test = self()

    assert %LoadedFile{data: %{routes: ["/a"]}} = Watcher.current(Routes, :routes)

    sub = Watcher.subscribe(Routes, :routes)
    fun1 = Watcher.on_change(Routes, :routes, fn file -> send(test, {:hook1, file.data}) end)
    _fun2 = Watcher.on_change(Routes, :routes, fn file -> send(test, {:hook2, file.data}) end)

    put(root, "etc/svc/routes/routes.json", ~s({"routes": ["/a", "/b"]}))

    assert_receive {:docuconf_reloaded, Routes, :routes,
                    %LoadedFile{data: %{routes: ["/a", "/b"]}}},
                   1_000

    assert_receive {:hook1, %{routes: ["/a", "/b"]}}, 1_000
    assert_receive {:hook2, %{routes: ["/a", "/b"]}}, 1_000
    assert Watcher.current(Routes, :routes).data == %{routes: ["/a", "/b"]}

    # A rejected change: no hook, and the previous value stays current.
    put(root, "etc/svc/routes/routes.json", ~s({"routes": "nope"}))
    assert_eventually(fn -> Watcher.status(Routes, :routes).last_rejected != nil end)
    refute_receive {:docuconf_reloaded, _, _, _}, 100
    refute_receive {:hook1, _}, 0
    refute_receive {:hook2, _}, 0
    assert Watcher.current(Routes, :routes).data == %{routes: ["/a", "/b"]}

    # Unsubscribed hooks stop; the others go on.
    :ok = Watcher.unsubscribe(Routes, sub)
    :ok = Watcher.unsubscribe(Routes, fun1)
    put(root, "etc/svc/routes/routes.json", ~s({"routes": ["/c"]}))
    assert_receive {:hook2, %{routes: ["/c"]}}, 1_000
    refute_receive {:docuconf_reloaded, _, _, _}, 100
    refute_receive {:hook1, _}, 0
  end

  test "a hook that raises, throws or exits is logged and does not stop the reload", %{root: root} do
    test = self()

    log =
      capture_log(fn ->
        start(Thrower, root, on_change: fn _field, file -> raise "boom: " <> file.data end)

        Watcher.on_change(Thrower, :motd, fn file -> throw(file.data) end)
        Watcher.on_change(Thrower, :motd, fn file -> exit(file.data) end)
        Watcher.on_change(Thrower, :motd, fn file -> send(test, {:after, file.data}) end)

        put(root, "etc/svc/motd/motd.txt", "secret-content")
        assert_receive {:after, "secret-content"}, 1_000
        assert Watcher.status(Thrower, :motd).generation == 2
        assert Watcher.current(Thrower, :motd).data == "secret-content"
      end)

    assert log =~ "a reload hook for motd raised RuntimeError"
    assert log =~ "a reload hook for motd failed (throw)"
    assert log =~ "a reload hook for motd failed (exit)"
    refute log =~ "secret-content"
  end

  test "the status counts accepted reloads and records the last rejected change", %{root: root} do
    start(Routes, root)

    assert %ReloadStatus{generation: 1, last_reload: nil, last_rejected: nil} =
             Watcher.status(Routes, :routes)

    assert Watcher.status(Routes) == %{routes: Watcher.status(Routes, :routes)}

    put(root, "etc/svc/routes/routes.json", ~s({"routes": ["/b"]}))
    assert_eventually(fn -> Watcher.status(Routes, :routes).generation == 2 end)

    %ReloadStatus{last_reload: %DateTime{} = t1, last_rejected: nil} =
      Watcher.status(Routes, :routes)

    put(root, "etc/svc/routes/routes.json", ~s({"routes": "not-a-list"}))
    assert_eventually(fn -> Watcher.status(Routes, :routes).last_rejected != nil end)

    assert %ReloadStatus{
             generation: 2,
             last_reload: ^t1,
             last_rejected: %RejectedReload{
               time: %DateTime{},
               input: "routes",
               codes: [:schema_mismatch]
             }
           } = status = Watcher.status(Routes, :routes)

    json = JSON.encode!(status)
    assert json =~ ~s("generation":2)
    assert json =~ ~s("codes":["schema_mismatch"])
    refute json =~ "not-a-list"

    # The next accepted reload clears it.
    put(root, "etc/svc/routes/routes.json", ~s({"routes": ["/c"]}))
    assert_eventually(fn -> Watcher.status(Routes, :routes).generation == 3 end)

    assert %ReloadStatus{last_rejected: nil, last_reload: %DateTime{}} =
             Watcher.status(Routes, :routes)
  end

  test "an input that is not watched, or no watcher, is an ArgumentError", %{root: root} do
    assert_raise ArgumentError, ~r/no Docuconf.Watcher is running/, fn ->
      Watcher.current(Routes, :routes)
    end

    start(Routes, root)

    assert_raise ArgumentError, ~r/:motd is not a reload: :watch input/, fn ->
      Watcher.current(Routes, :motd)
    end

    assert_raise ArgumentError, ~r/:motd is not a reload: :watch input/, fn ->
      Watcher.subscribe(Routes, :motd)
    end
  end

  test "a keystore reload reuses the boot password; a different one is keystore_unreadable",
       %{root: root} do
    openssl = System.find_executable("openssl") || flunk("openssl is needed")
    pki = Certs.ca_and_leaf(["partner.example.com"])
    src = Path.join(root, "src")
    File.mkdir_p!(src)
    File.write!(Path.join(src, "c.pem"), Certs.cert_pem([pki.leaf]))
    File.write!(Path.join(src, "k.pem"), Certs.key_pem(pki.leaf_key))
    File.mkdir_p!(Path.join(root, "etc/svc/partner"))

    p12 = fn password ->
      out = Path.join(src, "ks-#{System.unique_integer([:positive])}.p12")

      {_, 0} =
        System.cmd(
          openssl,
          ~w(pkcs12 -export -in #{src}/c.pem -inkey #{src}/k.pem -out #{out} -passout pass:#{password}),
          stderr_to_stdout: true
        )

      File.rename!(out, Path.join(root, "etc/svc/partner/ks.p12"))
    end

    p12.("boot-pw")
    env = %{"DOCUCONF_FILE_ROOT" => root, "KS_PASSWORD" => "boot-pw"}
    test = self()

    start_supervised!(
      {Watcher,
       module: Keystore,
       env: env,
       interval: 20,
       on_change: fn field, _ -> send(test, {:changed, field}) end,
       on_error: fn field, vs -> send(test, {:invalid, field, Enum.map(vs, & &1.code)}) end}
    )

    assert %LoadedFile{type: "keystore"} = before = Watcher.current(Keystore, :partner)

    # Rotated with a new password but no rollout: rejected, previous kept.
    p12.("rotated-pw")
    assert_receive {:invalid, :partner, [:keystore_unreadable]}, 1_000
    refute_received {:changed, :partner}
    assert Watcher.current(Keystore, :partner) == before

    assert %ReloadStatus{
             generation: 1,
             last_rejected: %RejectedReload{input: "partner", codes: [:keystore_unreadable]}
           } = Watcher.status(Keystore, :partner)

    # A new keystore with the boot password is accepted.
    p12.("boot-pw")
    assert_receive {:changed, :partner}, 1_000
    assert %ReloadStatus{generation: 2, last_rejected: nil} = Watcher.status(Keystore, :partner)
  end

  defmodule Serving do
    use Docuconf, name: "watched-serving"

    tls_file :serving_tls,
      description: "Certificate the API serves HTTPS with",
      path: "/etc/svc/tls",
      dns_names: ["localhost"],
      reload: :watch
  end

  # The README's TLS server pattern: certfile/keyfile paths, and a hook that
  # clears OTP's PEM cache, serve the renewed certificate on the next
  # handshake.
  test "a TLS listener serves a renewed certificate after the README's hook", %{root: root} do
    dir = Path.join(root, "etc/svc/tls")
    first = Certs.cert(key: key1 = Certs.key(:ec), cn: "localhost", dns: ["localhost"])
    Certs.write_tls_dir(dir, [first], key1)
    start(Serving, root)
    test = self()

    Watcher.on_change(Serving, :serving_tls, fn _tls ->
      :ssl.clear_pem_cache()
      send(test, :renewed)
    end)

    tls = Watcher.current(Serving, :serving_tls)

    {:ok, listen} =
      :ssl.listen(0, certfile: tls.data.certfile, keyfile: tls.data.keyfile, reuseaddr: true)

    on_exit(fn -> :ssl.close(listen) end)
    {:ok, {_, port}} = :ssl.sockname(listen)

    accept = fn accept ->
      with {:ok, s} <- :ssl.transport_accept(listen) do
        _ = :ssl.handshake(s, 5_000)
        accept.(accept)
      end
    end

    spawn_link(fn -> accept.(accept) end)

    served = fn ->
      {:ok, c} = :ssl.connect(~c"localhost", port, [verify: :verify_none, active: false], 5_000)
      {:ok, der} = :ssl.peercert(c)
      :ssl.close(c)
      der
    end

    assert served.() == first

    second = Certs.cert(key: key2 = Certs.key(:ec), cn: "localhost", dns: ["localhost"])
    new_dir = Path.join(root, "new-tls")
    Certs.write_tls_dir(new_dir, [second], key2)
    File.rename!(Path.join(new_dir, "tls.key"), Path.join(dir, "tls.key"))
    File.rename!(Path.join(new_dir, "tls.crt"), Path.join(dir, "tls.crt"))
    assert_receive :renewed, 2_000
    assert served.() == second
  end

  defp assert_eventually(fun, tries \\ 100) do
    cond do
      fun.() -> :ok
      tries == 0 -> flunk("condition never held")
      true -> Process.sleep(10) && assert_eventually(fun, tries - 1)
    end
  end
end

defmodule Docuconf.WatcherCheckTest do
  use ExUnit.Case, async: true

  # One module per test: the check is per module.
  defmodule Unwatched do
    use Docuconf, name: "unwatched"

    text_file :motd,
      description: "Message of the day",
      path: "/etc/svc/motd/motd.txt",
      required: false,
      reload: :watch
  end

  defmodule Watched do
    use Docuconf, name: "watched"

    text_file :motd,
      description: "Message of the day",
      path: "/etc/svc/motd/motd.txt",
      required: false,
      reload: :watch
  end

  defmodule Restart do
    use Docuconf, name: "restart"

    text_file :motd, description: "Message of the day", path: "/etc/svc/motd/motd.txt"
  end

  defp load(module, opts) do
    test = self()

    module.load(
      opts ++
        [
          env: %{},
          termination_log: false,
          warn: false,
          watcher_grace: 20,
          watcher_check: fn msg -> send(test, {:unwatched, module, msg}) end
        ]
    )
  end

  test "a watch input with no watcher running is reported" do
    assert {:ok, _} = load(Unwatched, [])
    assert_receive {:unwatched, Unwatched, msg}, 1_000
    assert msg =~ "Docuconf.WatcherCheckTest.Unwatched declares reload: watch for motd"
    assert msg =~ "{Docuconf.Watcher, module: Docuconf.WatcherCheckTest.Unwatched"
  end

  test "a module in a started application is checked once it has started" do
    module = Docuconf.Test.AppWatchedEnv
    assert Application.get_application(module) == :docuconf
    assert {:ok, _} = load(module, watcher_grace: 60_000)
    assert_receive {:unwatched, ^module, _}, 1_000
  end

  test "a running watcher satisfies the check" do
    start_supervised!(
      {Docuconf.Watcher, module: Watched, env: %{}, on_change: fn _, _ -> :ok end}
    )

    assert {:ok, _} = load(Watched, [])
    refute_receive {:unwatched, Watched, _}, 200
  end

  test "no watch inputs, no check" do
    assert {:ok, _} = load(Restart, [])
    refute_receive {:unwatched, Restart, _}, 200
  end

  test "an invalid :watcher_check is rejected" do
    assert_raise ArgumentError, ~r/:watcher_check must be/, fn ->
      load(Unwatched, watcher_check: :sometimes)
    end
  end

  @tag :tmp_dir
  test "by default the node stops, with the problem in the termination log", %{tmp_dir: dir} do
    log = Path.join(dir, "termination-log")

    script = """
    defmodule Boot.Env do
      use Docuconf, name: "boot"
      text_file :motd, description: "Message of the day", path: "/etc/boot/motd.txt",
        required: false, reload: :watch
    end
    Boot.Env.load!(watcher_grace: 50)
    Process.sleep(10_000)
    IO.puts("still running")
    """

    elixir = System.find_executable("elixir")

    {out, status} =
      System.cmd(elixir, ["-pa", Path.join(:code.lib_dir(:docuconf), "ebin"), "-e", script],
        env: [{"DOCUCONF_TERMINATION_LOG", log}],
        stderr_to_stdout: true
      )

    assert status == 1
    assert out =~ "Boot.Env declares reload: watch for motd, but no Docuconf.Watcher is running"
    refute out =~ "still running"
    # Printed once, not once raw and once through Logger.
    assert length(String.split(out, "no Docuconf.Watcher is running")) == 2
    assert File.read!(log) =~ "no Docuconf.Watcher is running"
  end
end
