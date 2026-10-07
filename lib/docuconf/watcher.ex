defmodule Docuconf.Watcher do
  @moduledoc """
  Honours `reload: :watch` (SPEC §11.2 item 8): polls every file input that
  declares it, re-runs its boot checks when it changes, and hands the new
  value to your callback.

  Kubernetes updates projected volumes by swapping a `..data` symlink in the
  mount directory, so the watcher fingerprints the mount directory's
  `..data` target together with each file's inode, size, mtime and (for
  files up to 1 MiB) content hash. OTP has no portable inotify, so this
  polls; the default interval is 5 seconds.

  Add it to your supervision tree:

      children = [
        {Docuconf.Watcher,
         module: MyApp.Env,
         on_change: fn :routes, file -> MyApp.Router.reload(file.data) end}
      ]

  Options:

    * `:module` - the `use Docuconf` module (required);
    * `:on_change` - `fn field, %Docuconf.LoadedFile{} -> any end`, called
      after a changed file passes its checks (required);
    * `:on_error` - `fn field, [%Docuconf.Violation{}] -> any end`, called
      when a changed file fails its checks; the app keeps its previous
      value. Defaults to logging a warning;
    * `:interval` - poll interval in milliseconds (default 5000);
    * `:env`, `:dotenv`, `:fallback_env`, `:file_root` - as for
      `Docuconf.load/2`. By default the watcher reads the environment the
      way the module's last successful `load` did (the same `:dotenv`,
      `:fallback_env` and `:file_root`), so a `DOCUCONF_FILE_ROOT` set in
      `.env` applies to both.

  ## The watcher must run

  A `reload: :watch` input tells the platform not to restart the pod when
  the file changes, so a missing watcher means the app silently keeps stale
  content. `Docuconf.load/2` therefore checks, once the application that
  owns the declaration module has started, that a watcher for that module is
  running, and by default stops the node if it is not. See the
  `:watcher_check` option of `Docuconf.load/2`.
  """

  use GenServer
  require Logger

  alias Docuconf.Files

  @hash_limit 1_048_576

  def start_link(opts) do
    {gen_opts, opts} = Keyword.split(opts, [:name])
    GenServer.start_link(__MODULE__, opts, gen_opts)
  end

  def child_spec(opts) do
    %{id: Keyword.get(opts, :name, __MODULE__), start: {__MODULE__, :start_link, [opts]}}
  end

  @impl true
  def init(opts) do
    module = Keyword.fetch!(opts, :module)
    decl = module.__docuconf__()
    env_opts = Keyword.merge(remembered(module), opts)
    {env, _warnings} = Docuconf.Loader.environment(env_opts)
    file_root = Keyword.get(env_opts, :file_root) || Map.get(env, "DOCUCONF_FILE_ROOT")
    watched = Enum.filter(decl.files, &(&1.reload == "watch"))
    :persistent_term.put({__MODULE__, module}, self())

    state = %{
      decl: decl,
      env: env,
      file_root: file_root,
      on_change: Keyword.fetch!(opts, :on_change),
      on_error: Keyword.get(opts, :on_error, &log_error/2),
      interval: Keyword.get(opts, :interval, 5_000),
      files: Map.new(watched, fn f -> {f.name, {f, fingerprint(f, path(f, env, file_root))}} end)
    }

    if watched != [], do: schedule(state)
    {:ok, state}
  end

  # The state holds the whole environment, secrets included; crash reports
  # and :sys.get_status/1 show it without the values.
  @impl true
  def format_status(status) do
    Map.update(status, :state, nil, fn
      %{env: env} = state -> %{state | env: "(#{map_size(env)} variables, not shown)"}
      other -> other
    end)
  end

  @impl true
  def handle_info(:poll, state) do
    files =
      Map.new(state.files, fn {name, {f, old}} ->
        path = path(f, state.env, state.file_root)
        new = fingerprint(f, path)
        if new != old, do: changed(f, state)
        {name, {f, new}}
      end)

    state = %{state | files: files}
    schedule(state)
    {:noreply, state}
  end

  defp changed(f, state) do
    vars = parsed_vars(state)

    case Files.load(f, state.env, vars, file_root: state.file_root) do
      {nil, []} -> :ok
      {value, []} -> safely(fn -> state.on_change.(f.field, value) end)
      {_, violations} -> safely(fn -> state.on_error.(f.field, violations) end)
    end
  end

  # Keystore passwords come from declared secret variables.
  defp parsed_vars(state) do
    for v <- state.decl.vars, raw = Map.get(state.env, v.name), raw not in [nil, ""], into: %{} do
      case Docuconf.Value.parse(v, raw) do
        {:ok, val} -> {v.name, val}
        _ -> {v.name, nil}
      end
    end
  end

  defp safely(fun) do
    fun.()
  rescue
    e -> Logger.error("docuconf: watch callback failed: " <> Exception.message(e))
  end

  defp log_error(field, violations) do
    Logger.warning(
      "docuconf: #{field} changed but is invalid, keeping the previous value:\n" <>
        Enum.map_join(violations, "\n", &("  - " <> Docuconf.Violation.format(&1)))
    )
  end

  @remembered [:dotenv, :fallback_env, :file_root]

  @doc false
  # Called by Docuconf.load/2 after a successful load from the process
  # environment: records how it read the environment (never the values), so
  # the watcher reads it the same way.
  def remember(module, opts) do
    unless Keyword.has_key?(opts, :env) do
      kept = Keyword.take(opts, @remembered)
      key = {__MODULE__, :load_opts, module}
      if :persistent_term.get(key, nil) != kept, do: :persistent_term.put(key, kept)
    end

    :ok
  end

  defp remembered(module), do: :persistent_term.get({__MODULE__, :load_opts, module}, [])

  @doc false
  # Is a watcher running for `module`?
  def running?(module) do
    case :persistent_term.get({__MODULE__, module}, nil) do
      pid when is_pid(pid) -> Process.alive?(pid)
      nil -> false
    end
  end

  @doc false
  # Called by Docuconf.load/2 after a successful load. When the declaration
  # has `reload: :watch` inputs, a guard process waits until the module's
  # application has started (its supervision tree is then up) and checks
  # that a watcher for the module is running. One guard per module.
  def expect(module, decl, opts) do
    default = if Keyword.has_key?(opts, :env), do: false, else: :halt
    mode = Keyword.get(opts, :watcher_check, default)
    watched = for f <- decl.files, f.reload == "watch", do: f.name

    if mode not in [false, nil] and watched != [] do
      validate_mode!(mode)
      grace = Keyword.get(opts, :watcher_grace, 5_000)
      parent = self()

      {pid, ref} =
        spawn_monitor(fn ->
          registered =
            try do
              Process.register(self(), guard_name(module))
            rescue
              ArgumentError -> false
            end

          send(parent, {:docuconf_guard, self()})
          if registered, do: guard(module, watched, mode, grace, opts)
        end)

      receive do
        {:docuconf_guard, ^pid} -> Process.demonitor(ref, [:flush])
        {:DOWN, ^ref, _, _, _} -> :ok
      end
    end

    :ok
  end

  defp validate_mode!(mode) when mode in [:halt, :warn] or is_function(mode, 1), do: :ok

  defp validate_mode!(mode) do
    raise ArgumentError,
          "docuconf: :watcher_check must be :halt, :warn, false or a 1-arity function, got: " <>
            inspect(mode)
  end

  defp guard_name(module), do: :"#{__MODULE__}.Guard.#{inspect(module)}"

  defp guard(module, watched, mode, grace, opts) do
    case Application.get_application(module) do
      nil -> Process.sleep(grace)
      app -> wait_started(app, 10)
    end

    unless running?(module), do: unwatched(module, watched, mode, opts)
  end

  defp wait_started(app, delay) do
    unless List.keymember?(Application.started_applications(), app, 0) do
      Process.sleep(delay)
      wait_started(app, min(delay * 2, 1_000))
    end
  end

  defp unwatched(module, watched, mode, opts) do
    message =
      "docuconf: #{inspect(module)} declares reload: watch for #{Enum.join(watched, ", ")}, " <>
        "but no Docuconf.Watcher is running for it. The contract promises the app rereads " <>
        "these files, so the platform will not restart the pod when they change. Add " <>
        "{Docuconf.Watcher, module: #{inspect(module)}, on_change: ...} to your supervision " <>
        "tree, or declare reload: :restart."

    case mode do
      fun when is_function(fun, 1) ->
        fun.(message)

      :warn ->
        Logger.error(message)

      # Printed once, to standard error: Logger may not flush before the
      # node stops.
      :halt ->
        IO.puts(:stderr, message)
        Docuconf.Loader.write_termination_log(message, opts)
        System.stop(1)
    end
  end

  defp schedule(state), do: Process.send_after(self(), :poll, state.interval)

  defp path(f, env, file_root), do: Files.resolve_path(f, env, file_root)

  @doc false
  def fingerprint(%{type: "tls"}, dir) do
    {data_link(dir), Enum.map(~w(tls.crt tls.key ca.crt), &file_print(Path.join(dir, &1)))}
  end

  def fingerprint(_f, path), do: {data_link(Path.dirname(path)), file_print(path)}

  defp data_link(dir) do
    case File.read_link(Path.join(dir, "..data")) do
      {:ok, target} -> target
      _ -> nil
    end
  end

  defp file_print(path) do
    case File.stat(path, time: :posix) do
      {:ok, %File.Stat{size: size, mtime: mtime, inode: inode}} ->
        hash =
          if size <= @hash_limit do
            case File.read(path) do
              {:ok, bin} -> :crypto.hash(:sha256, bin)
              _ -> nil
            end
          end

        {inode, size, mtime, hash}

      {:error, reason} ->
        reason
    end
  end
end
