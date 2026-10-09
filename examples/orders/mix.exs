defmodule Orders.MixProject do
  use Mix.Project

  def project do
    [
      app: :orders,
      version: "1.0.0",
      elixir: "~> 1.18",
      # The SDK from this repository, not a published version.
      deps: [{:docuconf, path: "../.."}],
      # `mix docuconf.export` exports this module's contract.
      docuconf: [module: Orders.Env],
      # The tests load Orders.Env from maps; they do not start the server.
      aliases: [test: "test --no-start"]
    ]
  end

  # :inets is OTP's own HTTP server (:httpd), so the example needs no Hex packages.
  def application, do: [mod: {Orders.Application, []}, extra_applications: [:logger, :inets]]
end
