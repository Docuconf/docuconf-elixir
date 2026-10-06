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
    assert File.read!(log) =~ "no Docuconf.Watcher is running"
  end
end
