defmodule Orders.MixProject do
  use Mix.Project

  def project do
    [
      app: :orders,
      version: "1.4.0",
      elixir: "~> 1.18",
      deps: [{:docuconf, path: "../.."}],
      # `mix docuconf.export` exports this module's contract.
      docuconf: [module: Orders.Env]
    ]
  end

  def application, do: [extra_applications: [:logger]]
end
