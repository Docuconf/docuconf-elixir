defmodule Mix.Tasks.Docuconf.Export do
  @shortdoc "Writes the docuconf contract (contract.cue) for a declaration module"

  @moduledoc """
  Writes a declaration's contract as CUE.

      mix docuconf.export MyApp.Env
      mix docuconf.export MyApp.Env --output deploy/contract.cue --package orders

  The module can also be set in `mix.exs`:

      def project do
        [..., docuconf: [module: MyApp.Env]]
      end

  Options:

    * `--output`, `-o` - file to write (default `contract.cue`; `-` for stdout)
    * `--package` - CUE package name (default: the service name, with `-` as `_`)
    * `--app-version` - `metadata.appVersion` (default: the project version)
    * `--check` - do not write; fail if the file is missing or out of date
      (for CI), printing the difference and the command that updates it.
      `metadata.appVersion` and the generator version are not compared, so
      a version bump in `mix.exs` or an SDK upgrade does not fail the check

  With `--output -` the task compiles your project silently, so stdout
  holds only the contract. On a build where not even docuconf itself is
  compiled yet, Mix compiles it (and prints that) before this task can run;
  in a fresh CI job or Dockerfile run `mix deps.compile` first, or write the
  file with `--output contract.cue`.
  """

  use Mix.Task

  @switches [output: :string, package: :string, app_version: :string, check: :boolean]

  @impl true
  def run(argv) do
    {opts, args} = OptionParser.parse!(argv, strict: @switches, aliases: [o: :output])
    output = opts[:output] || "contract.cue"

    if output == "-" and !opts[:check],
      do: quietly(fn -> Mix.Task.run("compile", []) end),
      else: Mix.Task.run("compile", [])

    project = Mix.Project.config()

    module =
      case args do
        [m] ->
          Module.concat([m])

        [] ->
          get_in(project, [:docuconf, :module]) ||
            Mix.raise("usage: mix docuconf.export MyApp.Env")

        _ ->
          Mix.raise("usage: mix docuconf.export MyApp.Env [--output contract.cue]")
      end

    Code.ensure_loaded(module)

    unless function_exported?(module, :__docuconf__, 0),
      do: Mix.raise("#{inspect(module)} is not a docuconf declaration (use Docuconf)")

    export_opts =
      [app_version: opts[:app_version] || project[:version]]
      |> then(&if(opts[:package], do: Keyword.put(&1, :package, opts[:package]), else: &1))

    cue = Docuconf.export(module, export_opts)

    cond do
      opts[:check] ->
        command = Enum.join(["mix docuconf.export" | argv -- ["--check"]], " ")

        case File.read(output) do
          {:ok, current} ->
            if comparable(current) == comparable(cue) do
              Mix.shell().info("#{output} is up to date")
            else
              Mix.raise("#{output} is out of date; run: #{command}\n" <> diff(current, cue))
            end

          {:error, reason} ->
            Mix.raise("#{output} cannot be read (#{:file.format_error(reason)}); run: #{command}")
        end

      output == "-" ->
        IO.write(cue)

      true ->
        File.mkdir_p!(Path.dirname(output))
        File.write!(output, cue)
        Mix.shell().info("wrote #{output}")
    end
  end

  defp quietly(fun) do
    shell = Mix.shell()
    Mix.shell(Mix.Shell.Quiet)

    try do
      fun.()
    after
      Mix.shell(shell)
    end
  end

  # The app and SDK versions change on every release; they are not part of
  # what the contract promises, so --check ignores them.
  defp comparable(cue) do
    cue
    |> String.replace(~r/^\t\tappVersion: .*\n/m, "")
    |> String.replace(~r/^\t\tgenerator: \{\n.*?^\t\t\}\n/ms, "")
  end

  @diff_lines 20

  defp diff(old, new) do
    lines =
      String.split(old, "\n")
      |> List.myers_difference(String.split(new, "\n"))
      |> Enum.flat_map(fn
        {:eq, _} -> []
        {:del, ls} -> Enum.map(ls, &("-" <> &1))
        {:ins, ls} -> Enum.map(ls, &("+" <> &1))
      end)

    shown = Enum.take(lines, @diff_lines)
    more = length(lines) - length(shown)
    Enum.join(shown, "\n") <> if(more > 0, do: "\n... #{more} more changed lines", else: "")
  end
end
