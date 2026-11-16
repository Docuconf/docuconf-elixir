defmodule Shop.MixProject do
  use Mix.Project

  def project do
    [
      app: :shop,
      version: "1.0.0",
      elixir: "~> 1.18",
      # The SDK from this repository, not a published version.
      deps: [{:docuconf, path: "../.."}]
    ]
  end

  def application, do: [extra_applications: [:logger]]
end
