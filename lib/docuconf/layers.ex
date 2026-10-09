defmodule Docuconf.Layers do
  @moduledoc false
  # Profiles and config-file overlays (SPEC §4.4, §4.7) in contract-first
  # mode. Elixir's config/*.exs files are compiled into the release, so a
  # `use Docuconf` declaration has neither; a contract written for a host
  # that layers files (.NET, Spring, Rails) may have both, and
  # Docuconf.Contract layers them as that host would: the variable's
  # default, then the selected profile's default, then an overlay, then the
  # environment.

  alias Docuconf.{Declaration, Duration, Value, Var, Violation}

  @reserved_dirs ~w(/ /app /bin /boot /dev /etc /etc/pki /etc/ssl /etc/ssl/certs /home /lib /lib64
                    /opt /proc /root /run /sbin /srv /sys /tmp /usr /usr/lib /usr/local /usr/share
                    /var /var/lib /var/run)

  defmodule Profiles do
    @moduledoc false
    # defaults: profile name => variable name => typed (internal) value.
    @type t :: %__MODULE__{}
    defstruct [:selector, :default, defaults: %{}]
  end

  defmodule Overlay do
    @moduledoc false
    @type t :: %__MODULE__{}
    defstruct [:name, :format, :path, :key_separator, :decoder, reload: "restart"]
  end

  # ---- declaration ------------------------------------------------------------

  @doc """
  Parses a contract's `profiles` block against the declared variables.
  Returns `{profiles | nil, problems}`.
  """
  def parse_profiles(nil, _vars), do: {nil, []}

  def parse_profiles(%{} = p, vars) do
    unknown = Map.keys(p) -- ["selector", "default", "defaults"]
    selector = p["selector"]
    sel_var = Enum.find(vars, &(&1.name == selector))
    defaults = Map.get(p, "defaults", %{})

    problems =
      Enum.map(unknown, &"profiles: unknown field #{&1}") ++
        if(sel_var == nil,
          do: ["profiles.selector #{inspect(selector)} must be a declared variable"],
          else: []
        ) ++
        if(is_binary(p["default"]), do: [], else: ["profiles.default must be a string"]) ++
        if(is_map(defaults), do: [], else: ["profiles.defaults must be an object"])

    {typed, more} =
      if is_map(defaults) do
        defaults
        |> Enum.sort()
        |> Enum.map_reduce([], fn {profile, values}, acc ->
          {vals, ps} = profile_values(profile, values, vars)
          {{profile, vals}, acc ++ ps}
        end)
      else
        {[], []}
      end

    {%Profiles{selector: selector, default: p["default"], defaults: Map.new(typed)},
     problems ++ more}
  end

  def parse_profiles(_other, _vars), do: {nil, ["profiles must be an object"]}

  defp profile_values(profile, %{} = values, vars) do
    values
    |> Enum.sort()
    |> Enum.reduce({%{}, []}, fn {name, value}, {acc, ps} ->
      where = "profiles.defaults.#{profile}: #{name}"

      case Enum.find(vars, &(&1.name == name)) do
        nil ->
          {acc, ps ++ ["#{where} is not a declared variable"]}

        %Var{secret: true} ->
          {acc, ps ++ ["#{where} is secret, and a secret has no value in a config file"]}

        var ->
          case typed(var, value) do
            {:ok, v} -> {Map.put(acc, name, v), ps}
            {:error, msg} -> {acc, ps ++ ["#{where}: #{msg}"]}
          end
      end
    end)
  end

  defp profile_values(profile, _values, _vars),
    do: {%{}, ["profiles.defaults.#{profile} must be an object"]}

  # A typed contract value (a profile default) in the internal form, checked
  # against the variable's constraints, as a default is.
  defp typed(%Var{type: "duration"} = var, s) when is_binary(s) do
    case Duration.parse(s) do
      {:ok, ns} -> check(var, ns)
      :error -> {:error, "#{inspect(s)} is not a Go duration such as \"1m30s\""}
    end
  end

  defp typed(%Var{type: "duration"}, other),
    do: {:error, "#{inspect(other)} is not a Go duration such as \"1m30s\""}

  defp typed(%Var{type: "float"} = var, n) when is_integer(n), do: check(var, n / 1)
  defp typed(var, value), do: check(var, value)

  defp check(var, v) do
    case Value.check(var, v) do
      {:ok, v} -> {:ok, v}
      {:error, code, msg} -> {:error, "#{msg} (#{code})"}
    end
  end

  @overlay_fields ~w(name description format path keySeparator reload)

  @doc """
  Parses a contract's `overlays` block. Returns `{overlays, problems}`,
  overlays sorted by name.
  """
  def parse_overlays(nil, _files, _decoders), do: {[], []}

  def parse_overlays(%{} = overlays, files, decoders) do
    {list, problems} =
      overlays
      |> Enum.sort()
      |> Enum.map_reduce([], fn {name, o}, acc ->
        {ov, ps} = overlay(name, o, decoders)
        {ov, acc ++ ps}
      end)

    list = Enum.reject(list, &is_nil/1)

    dirs =
      Enum.map(list, &{"overlay #{&1.name}", Path.dirname(&1.path)}) ++
        Enum.map(files, &{"file #{&1.name}", Declaration.mount_dir(&1)})

    shared =
      dirs
      |> Enum.group_by(&elem(&1, 1), &elem(&1, 0))
      |> Enum.filter(fn {_, owners} ->
        length(owners) > 1 and Enum.any?(owners, &String.starts_with?(&1, "overlay "))
      end)
      |> Enum.map(fn {dir, owners} ->
        "#{Enum.join(owners, ", ")} share mount directory #{dir}"
      end)

    reserved =
      for ov <- list, Path.dirname(ov.path) in @reserved_dirs do
        "overlay #{ov.name} would be mounted at reserved directory #{Path.dirname(ov.path)}"
      end

    {list, problems ++ shared ++ reserved}
  end

  def parse_overlays(_other, _files, _decoders), do: {[], ["overlays must be an object"]}

  defp overlay(name, %{} = o, decoders) do
    fail = fn msg -> "overlay #{name}: #{msg}" end
    path = o["path"]

    problems =
      [
        {not Regex.match?(~r/^[a-z]([-a-z0-9]*[a-z0-9])?\z/, name),
         fail.("name must be a DNS label")},
        {o["format"] not in ["json", "yaml", "toml"], fail.("format must be json, yaml or toml")},
        {not abs_path?(path), fail.("path #{inspect(path)} must be absolute and normalised")},
        {o["keySeparator"] not in [":", "."], fail.("keySeparator must be \":\" or \".\"")},
        {o["reload"] not in [nil, "restart", "watch"], fail.("reload must be restart or watch")},
        # Contract-first mode loads once and starts no watcher, so it
        # rejects the promise rather than break it (SPEC §11.2 item 8).
        {o["reload"] == "watch",
         fail.("reload \"watch\" is not supported in contract-first mode")}
      ]
      |> Enum.flat_map(fn {bad, msg} -> if bad, do: [msg], else: [] end)

    unknown = for k <- Map.keys(o), k not in @overlay_fields, do: fail.("unknown field #{k}")

    case problems ++ unknown do
      [] ->
        {%Overlay{
           name: name,
           format: o["format"],
           path: path,
           key_separator: o["keySeparator"],
           reload: o["reload"] || "restart",
           decoder: Docuconf.Contract.decoder_for(o["format"], decoders)
         }, []}

      ps ->
        {nil, ps}
    end
  end

  defp overlay(name, _o, _decoders), do: {nil, ["overlay #{name}: must be an object"]}

  defp abs_path?(p) when is_binary(p) do
    Regex.match?(~r/^\/[A-Za-z0-9._\/-]+\z/, p) and not Regex.match?(~r/(^|\/)\.\.?(\/|$)/, p) and
      not String.contains?(p, "//") and not String.ends_with?(p, "/")
  end

  defp abs_path?(_), do: false

  # ---- boot -------------------------------------------------------------------

  @doc """
  The layers below the environment, for each variable a profile or an
  overlay sets: a list, highest first, of `{:overlay, name, raw}` (a wire
  string or a list of item strings, checked like an env value),
  `{:profile, name, typed}`, or `:bad` (an overlay value already reported).
  Returns `{layers, violations, warnings}`.
  """
  def load(%Declaration{profiles: nil, overlays: []}, _env, _root), do: {%{}, [], []}

  def load(%Declaration{} = d, env, root) do
    profile_layers =
      case d.profiles do
        nil ->
          %{}

        p ->
          name = selected(p, d.vars, env)

          p.defaults
          |> Map.get(name, %{})
          |> Map.new(fn {var, typed} -> {var, [{:profile, name, typed}]} end)
      end

    selector = d.profiles && d.profiles.selector

    {overlay_layers, violations, warnings} =
      Enum.reduce(d.overlays, {%{}, [], []}, fn ov, acc ->
        read_overlay(ov, d.vars, selector, root, acc)
      end)

    layers =
      Map.merge(profile_layers, overlay_layers, fn _k, profile, overlay -> overlay ++ profile end)

    {layers, violations, warnings}
  end

  # The profile in effect: the selector's value when the environment sets it
  # (for a string selector, "" names a profile too), else profiles.default.
  defp selected(p, vars, env) do
    var = Enum.find(vars, &(&1.name == p.selector))

    case Map.fetch(env, p.selector) do
      {:ok, raw} when raw != "" -> raw
      {:ok, ""} when var.type == "string" -> ""
      _ -> p.default
    end
  end

  defp read_overlay(ov, vars, selector, root, {layers, vios, warns}) do
    path = if root in [nil, ""], do: ov.path, else: Path.join(root, ov.path)
    vio = fn code, msg -> Violation.new(ov.name, :file, code, msg) end

    case File.read(path) do
      {:error, :enoent} ->
        # An overlay is optional.
        {layers, vios, warns}

      {:error, reason} ->
        {layers, vios ++ [vio.(:file_unreadable, "#{path} cannot be read (#{reason})")], warns}

      {:ok, content} ->
        case decode(ov, strip_bom(content)) do
          {:ok, %{} = doc} ->
            Enum.reduce(vars, {layers, vios, warns}, fn var, acc ->
              overlay_var(ov, var, doc, selector, acc)
            end)

          {:ok, _} ->
            {layers, vios ++ [vio.(:file_malformed, "#{path} does not hold an object")], warns}

          {:error, detail} ->
            {layers,
             vios ++
               [
                 vio.(
                   :file_malformed,
                   "#{path} is not valid #{String.upcase(ov.format)} (#{detail})"
                 )
               ], warns}
        end
    end
  end

  defp overlay_var(_ov, %Var{config_key: nil}, _doc, _selector, acc), do: acc
  defp overlay_var(_ov, %Var{name: n}, _doc, n, acc), do: acc

  defp overlay_var(ov, %Var{} = var, doc, _selector, {layers, vios, warns}) do
    case lookup(doc, String.split(var.config_key, ov.key_separator)) do
      # A null is unset, like an empty env value.
      {:ok, nil} ->
        {layers, vios, warns}

      :error ->
        {layers, vios, warns}

      {:ok, value} ->
        at = "overlay #{ov.name}, at #{var.config_key}"

        cond do
          Enum.any?(Map.get(layers, var.name, []), &match?({:overlay, _, _}, &1)) ->
            {layers, vios,
             warns ++
               ["#{var.name} is set in two overlays; the first wins (#{ov.name} is ignored)"]}

          var.secret ->
            # Never printed: the value is secret material in a ConfigMap.
            msg =
              "is secret, but #{at} sets it; supply secrets through the environment"

            {Map.put(layers, var.name, [:bad]),
             vios ++ [Violation.new(var.name, :var, :invalid_type, msg)], warns}

          true ->
            case wire(var, value) do
              {:ok, raw} ->
                {Map.put(layers, var.name, [{:overlay, ov.name, raw}]), vios, warns}

              {:error, msg} ->
                {Map.put(layers, var.name, [:bad]),
                 vios ++ [Violation.new(var.name, :var, :invalid_type, "#{at}: #{msg}")], warns}
            end
        end
    end
  end

  defp lookup(doc, []), do: {:ok, doc}

  defp lookup(%{} = doc, [k | rest]) do
    case Map.fetch(doc, k) do
      {:ok, v} -> lookup(v, rest)
      :error -> :error
    end
  end

  defp lookup(_doc, _keys), do: :error

  # SPEC §4.7: a native value as the wire string it stands for.
  defp wire(%Var{type: "json"}, value), do: {:ok, JSON.encode!(value)}

  defp wire(%Var{type: t}, value) when t in ["list", "keySet"] do
    if is_list(value) do
      value
      |> Enum.with_index(1)
      |> Enum.reduce_while({:ok, []}, fn {item, i}, {:ok, acc} ->
        case scalar_text(item) do
          {:ok, s} -> {:cont, {:ok, [s | acc]}}
          :error -> {:halt, {:error, "item #{i} is #{kind(item)}, not a scalar"}}
        end
      end)
      |> case do
        {:ok, items} -> {:ok, Enum.reverse(items)}
        err -> err
      end
    else
      {:error, "is #{kind(value)}, not a list"}
    end
  end

  defp wire(_var, value) do
    case scalar_text(value) do
      {:ok, s} -> {:ok, s}
      :error -> {:error, "is #{kind(value)}, not a scalar"}
    end
  end

  # A number with an integral value is an integer (25.0 is 25); any other
  # in shortest round-trip decimal.
  defp scalar_text(s) when is_binary(s), do: {:ok, s}
  defp scalar_text(b) when is_boolean(b), do: {:ok, Atom.to_string(b)}
  defp scalar_text(i) when is_integer(i), do: {:ok, Integer.to_string(i)}

  defp scalar_text(f) when is_float(f) do
    if f == Float.round(f) and abs(f) < 9.223372036854776e18,
      do: {:ok, f |> trunc() |> Integer.to_string()},
      else: {:ok, Float.to_string(f)}
  end

  defp scalar_text(_), do: :error

  defp kind(%{}), do: "an object"
  defp kind(l) when is_list(l), do: "a list"
  defp kind(nil), do: "null"
  defp kind(_), do: "a scalar"

  defp decode(%Overlay{decoder: decoder}, content) do
    try do
      result =
        case decoder do
          {m, f} -> apply(m, f, [content])
          f -> f.(content)
        end

      case result do
        {:ok, v} -> {:ok, v}
        {:error, %{__exception__: true} = e} -> {:error, Exception.message(e)}
        {:error, reason} when is_binary(reason) -> {:error, reason}
        {:error, reason} -> {:error, Value.json_error(reason)}
        other -> {:error, "decoder returned #{inspect(other, limit: 3)}"}
      end
    rescue
      e -> {:error, Exception.message(e)}
    end
  end

  defp strip_bom(<<0xEF, 0xBB, 0xBF, rest::binary>>), do: rest
  defp strip_bom(s), do: s
end
