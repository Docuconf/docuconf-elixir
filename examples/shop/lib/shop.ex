defmodule Shop do
  @moduledoc """
  One program that runs as two workloads, a `web` server and a queue
  `worker`, configured by the hand-written contract in `contract.json`
  (contract-first mode). It has no server, database or queue: `main/0`
  loads the configuration, prints one line and exits 0, or lists every
  problem and exits 1.

      mix run -e "Shop.main()"
  """

  # The contract is read when this module compiles (a change to it
  # recompiles the module) and loaded, and checked, at every start.
  @contract_path Path.expand("../contract.json", __DIR__)
  @external_resource @contract_path
  @contract File.read!(@contract_path)

  @doc """
  Loads and validates the configuration against the contract. Takes the
  options of `Docuconf.Contract.load/2`; by default it reads the process
  environment and files under `DOCUCONF_FILE_ROOT`.
  """
  @spec load(keyword()) ::
          {:ok, Docuconf.Contract.Values.t()}
          | {:error, Docuconf.ValidationError.t() | Docuconf.DeclarationError.t()}
  def load(opts \\ []), do: Docuconf.Contract.load(@contract, opts)

  @doc """
  The line the app prints for a valid configuration, from the typed values.
  """
  @spec summary(Docuconf.Contract.Values.t()) :: String.t()
  def summary(values) do
    case values["DOCUCONF_ROLE"] do
      "web" ->
        "shop web: port #{values["PORT"]}, origins #{Enum.join(values["ALLOWED_ORIGINS"], ",")}"

      "worker" ->
        webhooks = if values["WEBHOOKS_ENABLED"], do: "on", else: "off"
        "shop worker: queues #{Enum.join(values["QUEUES"], ",")}, webhooks #{webhooks}"
    end
  end

  @doc """
  The entry point. With a valid configuration it prints `summary/1`, and
  `mix run` exits 0. Otherwise it prints `docuconf: N configuration
  problems:` and one line per problem to standard error, never a secret
  value, and stops with exit status 1. `Docuconf.Contract.load/2` has
  already written the same report to the termination log.
  """
  @spec main() :: :ok | no_return()
  def main do
    case load() do
      {:ok, values} ->
        IO.puts(summary(values))

      {:error, e} ->
        IO.puts(:stderr, Exception.message(e))
        System.halt(1)
    end
  end
end
