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
