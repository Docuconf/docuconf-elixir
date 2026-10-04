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
      (for CI)
  """

  use Mix.Task

  @switches [output: :string, package: :string, app_version: :string, check: :boolean]

  @impl true
  def run(argv) do
    {opts, args} = OptionParser.parse!(argv, strict: @switches, aliases: [o: :output])
    Mix.Task.run("compile", [])

    project = Mix.Project.config()

    module =
      case args do
        [m] -> Module.concat([m])
        [] -> get_in(project, [:docuconf, :module]) || Mix.raise("usage: mix docuconf.export MyApp.Env")
        _ -> Mix.raise("usage: mix docuconf.export MyApp.Env [--output contract.cue]")
      end

    Code.ensure_loaded(module)

    unless function_exported?(module, :__docuconf__, 0),
      do: Mix.raise("#{inspect(module)} is not a docuconf declaration (use Docuconf)")

    export_opts =
      [app_version: opts[:app_version] || project[:version]]
      |> then(&if(opts[:package], do: Keyword.put(&1, :package, opts[:package]), else: &1))

    cue = Docuconf.export(module, export_opts)
    output = opts[:output] || "contract.cue"

    cond do
      opts[:check] ->
        case File.read(output) do
          {:ok, ^cue} -> Mix.shell().info("#{output} is up to date")
          _ -> Mix.raise("#{output} is out of date; run mix docuconf.export")
        end

      output == "-" ->
        IO.write(cue)

      true ->
        File.mkdir_p!(Path.dirname(output))
        File.write!(output, cue)
        Mix.shell().info("wrote #{output}")
    end
  end
end
