defmodule Docuconf.Watcher do
  @moduledoc """
  Honours `reload: :watch` (SPEC §4.6.2, §11.2 item 8): polls every file
  input that declares it, re-runs its boot checks when it changes, and swaps
  in the new value only if they pass.

  Kubernetes updates projected volumes by swapping a `..data` symlink in the
  mount directory, so the watcher fingerprints the mount directory's
  `..data` target together with each file's inode, size, mtime and (for
  files up to 1 MiB) content hash. OTP has no portable inotify, so this
  polls in the background; the default interval is 5 seconds. Hooks fire
  from that poll, without the app reading anything.

  Add it to your supervision tree, before the processes that use the files:

      children = [
        {Docuconf.Watcher, module: MyApp.Files},
        MyApp.Endpoint
      ]

  Then, for each watched input:

    * `current/2` returns the value now in use. Read it at each use (each
      connection, each request) rather than copying it once at startup;
    * `subscribe/2` sends the calling process
      `{:docuconf_reloaded, module, field, %Docuconf.LoadedFile{}}` after
      each accepted reload, and `on_change/3` registers a function called
      with the new `Docuconf.LoadedFile`. Use either to rebuild what you made
      from the old value (an HTTP client's pool, a cache);
    * `status/2` returns a `Docuconf.ReloadStatus`: the generation, the last
      accepted reload and the last rejected change, for a health check.

  A change that fails its checks is never swapped in, never reaches a hook,
  and is recorded in the status by its violation codes; the previous value
  stays current.

  Options:

    * `:module` - the `use Docuconf` module (required);
    * `:on_change` - `fn field, %Docuconf.LoadedFile{} -> any end`, called
      after a changed file passes its checks, before the hooks added with
      `on_change/3` and `subscribe/2` (optional);
    * `:on_error` - `fn field, [%Docuconf.Violation{}] -> any end`, called
      when a changed file fails its checks; the app keeps its previous
      value. Defaults to logging a warning;
    * `:interval` - poll interval in milliseconds (default 5000);
    * `:env`, `:dotenv`, `:fallback_env`, `:file_root` - as for
      `Docuconf.load/2`. By default the watcher reads the environment the
      way the module's last successful `load` did (the same `:dotenv`,
      `:fallback_env` and `:file_root`), so a `DOCUCONF_FILE_ROOT` set in
      `.env` applies to both.

  The watcher reads the environment once, when it starts. A keystore reload
  therefore opens the new keystore with the password read at boot (the
  process environment does not change); rotating a keystore's password needs
  a rollout. A changed keystore that does not open with that password is
  rejected as `keystore_unreadable`.

  Hooks run in the watcher process, one at a time, in the order they were
  added (the `:on_change` option first). A hook that raises, throws or exits
  is logged by input name and error type only; the others still run and
  the reload stands. A hook added with `on_change/3` lasts until
  `unsubscribe/2`; a `subscribe/2` subscription also ends when the
  subscriber exits. Hooks and subscriptions belong to one watcher process:
  if it restarts, the generation starts again at 1 and they must be added
  again (a `:rest_for_one` supervisor does that for processes started after
  it).

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

  alias Docuconf.{Files, LoadedFile, RejectedReload, ReloadStatus}

  @hash_limit 1_048_576

  def start_link(opts) do
    {gen_opts, opts} = Keyword.split(opts, [:name])
    GenServer.start_link(__MODULE__, opts, gen_opts)
  end

  def child_spec(opts) do
    %{id: Keyword.get(opts, :name, __MODULE__), start: {__MODULE__, :start_link, [opts]}}
  end

  @doc """
  The current value of `module`'s watched input `field`: the one read at
  boot, or the last change that passed its checks. `nil` for an optional
  input that is absent. Reading it does not check the file; the background
  poll does.

  Raises `ArgumentError` when no watcher is running for `module` or `field`
  is not a `reload: :watch` input.
  """
  @spec current(module(), atom()) :: LoadedFile.t() | nil
  def current(module, field) do
    {file, _status} = row!(module, field)
    file
  end

  @doc """
  The `Docuconf.ReloadStatus` of `module`'s watched input `field`. Raises
  as `current/2` does.
  """
  @spec status(module(), atom()) :: ReloadStatus.t()
  def status(module, field) do
    {_file, status} = row!(module, field)
    status
  end

  @doc """
  The `Docuconf.ReloadStatus` of every watched input of `module`, by field.
  Raises `ArgumentError` when no watcher is running for `module`.
  """
  @spec status(module()) :: %{atom() => ReloadStatus.t()}
  def status(module) do
    {_pid, table} = whereis!(module)
    Map.new(:ets.tab2list(table), fn {field, _file, status} -> {field, status} end)
  end

  @doc """
  Subscribes the calling process to `module`'s watched input `field`: after
  each accepted reload it receives

      {:docuconf_reloaded, module, field, %Docuconf.LoadedFile{}}

  It never receives a rejected change. Returns a reference for
  `unsubscribe/2`; the subscription also ends when the process exits.
  Raises as `current/2` does.
  """
  @spec subscribe(module(), atom()) :: reference()
  def subscribe(module, field), do: add_hook(module, field, {:pid, self()})

  @doc """
  Registers `fun`, called with the new `Docuconf.LoadedFile` after each
  accepted reload of `module`'s watched input `field`, in the watcher
  process. Several functions may be registered; one that fails is logged
  by input name and error type and does not stop the others. Returns a
  reference for `unsubscribe/2`. Raises as `current/2` does.
  """
  @spec on_change(module(), atom(), (LoadedFile.t() -> any())) :: reference()
  def on_change(module, field, fun) when is_function(fun, 1),
    do: add_hook(module, field, {:fun, fun})

  @doc "Removes a hook added with `subscribe/2` or `on_change/3`."
  @spec unsubscribe(module(), reference()) :: :ok
  def unsubscribe(module, ref) when is_reference(ref) do
    {pid, _table} = whereis!(module)
    GenServer.call(pid, {:unsubscribe, ref})
  end

  defp add_hook(module, field, hook) do
    {pid, _table} = whereis!(module)

    case GenServer.call(pid, {:subscribe, field, hook}) do
      {:ok, ref} -> ref
      {:error, message} -> raise ArgumentError, message
    end
  end

  defp whereis!(module) do
    case :persistent_term.get({__MODULE__, module}, nil) do
      {pid, _table} = found when is_pid(pid) ->
        if Process.alive?(pid), do: found, else: no_watcher!(module)

      nil ->
        no_watcher!(module)
    end
  end

  defp no_watcher!(module),
    do: raise(ArgumentError, "docuconf: no Docuconf.Watcher is running for #{inspect(module)}")

  defp row!(module, field) do
    {_pid, table} = whereis!(module)

    # The table goes away with its watcher.
    rows =
      try do
        :ets.lookup(table, field)
      rescue
        ArgumentError -> no_watcher!(module)
      end

    case rows do
      [{^field, file, status}] -> {file, status}
      [] -> raise ArgumentError, not_watched(module, field)
    end
  end

  defp not_watched(module, field),
    do: "docuconf: #{inspect(field)} is not a reload: :watch input of #{inspect(module)}"

  @impl true
  def init(opts) do
    module = Keyword.fetch!(opts, :module)
    decl = module.__docuconf__()
    env_opts = Keyword.merge(remembered(module), opts)
    {env, _warnings} = Docuconf.Loader.environment(env_opts)
    file_root = Keyword.get(env_opts, :file_root) || Map.get(env, "DOCUCONF_FILE_ROOT")
    watched = Enum.filter(decl.files, &(&1.reload == "watch"))
    # Read once: a reload reuses the boot environment, keystore passwords
    # included.
    vars = parsed_vars(decl, env)
    table = :ets.new(__MODULE__, [:set, :protected, read_concurrency: true])

    for f <- watched do
      {file, _violations} = Files.load(f, env, vars, file_root: file_root)
      :ets.insert(table, {f.field, file, %ReloadStatus{generation: 1}})
    end

    :persistent_term.put({__MODULE__, module}, {self(), table})

    state = %{
      module: module,
      env: env,
      vars: vars,
      file_root: file_root,
      table: table,
      hooks: [],
      on_change: Keyword.get(opts, :on_change),
      on_error: Keyword.get(opts, :on_error, &log_error/2),
      interval: Keyword.get(opts, :interval, 5_000),
      files: Map.new(watched, fn f -> {f.name, {f, fingerprint(f, path(f, env, file_root))}} end)
    }

    if watched != [], do: schedule(state)
    {:ok, state}
  end

  # The state holds the whole environment and the parsed variables, secrets
  # included; crash reports and :sys.get_status/1 show them without values.
  @impl true
  def format_status(status) do
    Map.update(status, :state, nil, fn
      %{} = state ->
        Enum.reduce([:env, :vars], state, fn key, acc ->
          case acc do
            %{^key => %{} = m} -> %{acc | key => "(#{map_size(m)} variables, not shown)"}
            _ -> acc
          end
        end)

      other ->
        other
    end)
  end

  @impl true
  def handle_call({:subscribe, field, hook}, _from, state) do
    if :ets.member(state.table, field) do
      ref = make_ref()

      hook =
        case hook do
          {:pid, pid} -> {:pid, pid, Process.monitor(pid)}
          other -> other
        end

      {:reply, {:ok, ref}, %{state | hooks: state.hooks ++ [{ref, field, hook}]}}
    else
      {:reply, {:error, not_watched(state.module, field)}, state}
    end
  end

  def handle_call({:unsubscribe, ref}, _from, state) do
    {gone, hooks} = Enum.split_with(state.hooks, fn {r, _, _} -> r == ref end)
    for {_, _, {:pid, _, mon}} <- gone, do: Process.demonitor(mon, [:flush])
    {:reply, :ok, %{state | hooks: hooks}}
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

  def handle_info({:DOWN, mon, :process, _pid, _reason}, state) do
    hooks = Enum.reject(state.hooks, &match?({_, _, {:pid, _, ^mon}}, &1))
    {:noreply, %{state | hooks: hooks}}
  end

  defp changed(f, state) do
    case Files.load(f, state.env, state.vars, file_root: state.file_root) do
      {nil, []} -> :ok
      {value, []} -> accepted(f, value, state)
      {_, violations} -> rejected(f, violations, state)
    end
  end

  defp accepted(f, value, state) do
    [{_, _old, status}] = :ets.lookup(state.table, f.field)

    status = %ReloadStatus{
      generation: status.generation + 1,
      last_reload: DateTime.utc_now(),
      last_rejected: nil
    }

    :ets.insert(state.table, {f.field, value, status})

    if state.on_change, do: safely(f, fn -> state.on_change.(f.field, value) end)

    for {_ref, field, hook} <- state.hooks, field == f.field do
      case hook do
        {:fun, fun} -> safely(f, fn -> fun.(value) end)
        {:pid, pid, _mon} -> send(pid, {:docuconf_reloaded, state.module, f.field, value})
      end
    end

    :ok
  end

  defp rejected(f, violations, state) do
    [{_, file, status}] = :ets.lookup(state.table, f.field)

    rejected = %RejectedReload{
      time: DateTime.utc_now(),
      input: f.name,
      codes: violations |> Enum.map(& &1.code) |> Enum.uniq()
    }

    :ets.insert(state.table, {f.field, file, %{status | last_rejected: rejected}})
    safely(f, fn -> state.on_error.(f.field, violations) end)
  end

  # Keystore passwords come from declared secret variables.
  defp parsed_vars(decl, env) do
    for v <- decl.vars, raw = Map.get(env, v.name), raw not in [nil, ""], into: %{} do
      case Docuconf.Value.parse(v, raw) do
        {:ok, val} -> {v.name, val}
        _ -> {v.name, nil}
      end
    end
  end

  # A failing hook is logged by input name and error type, never its
  # message, which could quote the content.
  defp safely(f, fun) do
    fun.()
  rescue
    e -> Logger.error("docuconf: a reload hook for #{f.name} raised #{inspect(e.__struct__)}")
  catch
    kind, _ -> Logger.error("docuconf: a reload hook for #{f.name} failed (#{kind})")
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
      {pid, _table} when is_pid(pid) -> Process.alive?(pid)
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
        "{Docuconf.Watcher, module: #{inspect(module)}} to your supervision " <>
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
