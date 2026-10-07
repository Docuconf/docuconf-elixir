defmodule Docuconf.ReadmeTest do
  # Every Elixir block in README.md is compiled here, and the quickstart,
  # its test and the Phoenix recipe run in a fresh VM, so the README cannot
  # drift from the SDK. Blocks marked `<!-- snippet: NAME -->` are the ones
  # run.
  use ExUnit.Case, async: true

  @readme Path.expand("../README.md", __DIR__)
  @external_resource @readme
  @text File.read!(@readme)

  @blocks Regex.scan(~r/(?:<!-- snippet: ([a-z0-9-]+) -->\n)?```(\w+)\n(.*?)```/s, @text)
          |> Enum.map(fn [_, name, lang, code] -> %{name: name, lang: lang, code: code} end)

  defp snippet(name) do
    case Enum.find(@blocks, &(&1.name == name)) do
      %{code: code} -> code
      nil -> flunk("README.md has no snippet #{name}")
    end
  end

  describe "every Elixir block compiles" do
    for {%{lang: "elixir", name: name, code: code}, i} <- Enum.with_index(@blocks),
        # An ExUnit module is run below instead.
        name != "quickstart-test" do
      @tag code: code, index: i
      test "block #{i + 1} (#{if name == "", do: "unnamed", else: name})", %{code: code, index: i} do
        compile_block(code, i)
      end
    end
  end

  # Each block gets its own top-level alias in place of MyApp, so blocks
  # that each define MyApp.Env do not redefine one another. A block of plain
  # expressions is wrapped in a function, and run unless it is config code.
  defp compile_block(code, i) do
    prefix = :"Docuconf.ReadmeTest.Block#{i}"

    ast =
      code
      |> Code.string_to_quoted!()
      |> Macro.prewalk(fn
        {:__aliases__, m, [root | rest]} when root in [:MyApp, :MyAppWeb] ->
          {:__aliases__, m, [prefix, root | rest]}

        other ->
          other
      end)

    forms =
      case ast do
        {:__block__, _, forms} -> forms
        form -> [form]
      end

    kind =
      cond do
        Enum.any?(forms, &match?({:defmodule, _, _}, &1)) -> :modules
        Enum.any?(forms, &match?({d, _, _} when d in [:def, :defp], &1)) -> :defs
        true -> :exprs
      end

    wrapper = Module.concat([prefix, Snippet])

    quoted =
      case kind do
        :modules ->
          ast

        :defs ->
          quote do: defmodule(unquote(wrapper), do: unquote(ast))

        :exprs ->
          quote do
            defmodule unquote(wrapper) do
              def run, do: unquote(ast)
            end
          end
      end

    ExUnit.CaptureIO.capture_io(:stderr, fn -> Code.compile_quoted(quoted, "README.md") end)

    if kind == :exprs and not String.contains?(code, "import Config") do
      wrapper.run()
    end
  end

  # ---- running the quickstart in a fresh VM -------------------------------

  defp elixir(dir, script, env) do
    File.write!(Path.join(dir, "script.exs"), script)

    System.cmd(
      System.find_executable("elixir"),
      ["-pa", Path.join(:code.lib_dir(:docuconf), "ebin"), "script.exs"],
      cd: dir,
      env: [{"DOCUCONF_TERMINATION_LOG", Path.join(dir, "termination-log")} | env],
      stderr_to_stdout: true
    )
  end

  # Unset every variable the snippets declare, whatever the test's own
  # environment holds.
  @declared ~w(PORT LOG_LEVEL REQUEST_TIMEOUT DATABASE_URL PHX_SERVER PHX_HOST SECRET_KEY_BASE
               POOL_SIZE ECTO_IPV6 DNS_CLUSTER_QUERY DOCUCONF_FILE_ROOT)
  defp clean(env), do: Enum.map(@declared, &{&1, nil}) ++ env

  @tag :tmp_dir
  test "the quickstart's error is exactly what the README shows", %{tmp_dir: dir} do
    File.write!(Path.join(dir, "env.ex"), snippet("quickstart-env"))
    File.write!(Path.join(dir, "runtime.exs"), snippet("quickstart-runtime"))

    script = """
    Code.require_file("env.ex")
    Config.Reader.read!("runtime.exs", env: :prod)
    IO.puts("booted")
    """

    assert {out, 1} = elixir(dir, script, clean([{"PORT", "0"}]))
    assert out == snippet("quickstart-error")
    refute File.exists?(Path.join(dir, "erl_crash.dump"))

    db = [{"DATABASE_URL", "postgres://app:pw@localhost/app"}]
    assert {"booted\n", 0} = elixir(dir, script, clean(db))
  end

  @tag :tmp_dir
  test "the README's test passes", %{tmp_dir: dir} do
    File.write!(Path.join(dir, "env.ex"), snippet("quickstart-env"))
    File.write!(Path.join(dir, "env_test.exs"), snippet("quickstart-test"))

    script = """
    ExUnit.start(autorun: false)
    Code.require_file("env.ex")
    Code.require_file("env_test.exs")
    %{total: total, failures: failures} = ExUnit.run()
    IO.puts("total=\#{total} failures=\#{failures}")
    """

    {out, 0} = elixir(dir, script, clean([]))
    assert out =~ "total=3 failures=0"
  end

  describe "the Phoenix recipe" do
    @describetag :tmp_dir

    setup %{tmp_dir: dir} do
      File.write!(Path.join(dir, "env.ex"), snippet("phoenix-env"))
      File.write!(Path.join(dir, "runtime.exs"), snippet("phoenix-runtime"))
      :ok
    end

    defp boot(dir, config_env, env) do
      script = """
      Code.require_file("env.ex")
      config = Config.Reader.read!("runtime.exs", env: #{inspect(config_env)})
      endpoint = config[:my_app][MyAppWeb.Endpoint]
      repo = config[:my_app][MyApp.Repo]
      IO.inspect({endpoint[:server], endpoint[:http], endpoint[:url], repo[:pool_size],
                  byte_size(endpoint[:secret_key_base])}, width: :infinity)
      """

      elixir(dir, script, clean(env))
    end

    test "dev boots with no environment at all", %{tmp_dir: dir} do
      assert {out, 0} = boot(dir, :dev, [])
      assert out == "{nil, [port: 4000], nil, 10, 65}\n"
    end

    test "prod fails cleanly without its secrets", %{tmp_dir: dir} do
      assert {out, 1} = boot(dir, :prod, [])

      assert out == """
             docuconf: 2 configuration problems:
               - DATABASE_URL [missing_required]: required, but not set
               - SECRET_KEY_BASE [missing_required]: required, but not set
             """
    end

    test "prod with PHX_SERVER=true starts the endpoint", %{tmp_dir: dir} do
      env = [
        {"PHX_SERVER", "true"},
        {"PHX_HOST", "shop.example.com"},
        {"PORT", "8080"},
        {"SECRET_KEY_BASE", String.duplicate("k", 64)},
        {"DATABASE_URL", "ecto://u:p@db/shop"}
      ]

      assert {out, 0} = boot(dir, :prod, env)

      assert out ==
               ~s|{true, [port: 8080, ip: {0, 0, 0, 0, 0, 0, 0, 0}], [host: "shop.example.com", port: 443, scheme: "https"], 10, 64}\n|

      assert {out, 1} = boot(dir, :prod, [{"PHX_SERVER", "1"} | tl(env)])
      assert out =~ ~s(PHX_SERVER [invalid_type]: "1" is not true or false)
    end
  end
end
