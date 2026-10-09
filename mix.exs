defmodule Docuconf.MixProject do
  use Mix.Project

  @version "0.2.0"
  @source_url "https://github.com/docuconf/docuconf-elixir"
  @homepage_url "https://docuconf.dev/languages/elixir/"

  def project do
    [
      app: :docuconf,
      version: @version,
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
      deps: deps(),
      description:
        "Typed configuration contracts for Elixir apps: declare env vars and files " <>
          "for config/runtime.exs, validate them at boot and export a CUE contract.",
      package: package(),
      docs: docs(),
      source_url: @source_url,
      homepage_url: @homepage_url
    ]
  end

  def application do
    [extra_applications: [:logger, :crypto, :public_key]]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  # No runtime dependencies: JSON comes from Elixir's own JSON module
  # (Elixir 1.18+) and certificates from OTP's :public_key.
  defp deps do
    [
      {:ex_doc, "~> 0.34", only: :dev, runtime: false}
    ]
  end

  defp package do
    [
      licenses: ["MIT"],
      links: %{
        "GitHub" => @source_url,
        "Documentation" => @homepage_url,
        "Specification" => "https://docuconf.dev"
      },
      files: ~w(lib mix.exs README.md CHANGELOG.md LICENSE .formatter.exs)
    ]
  end

  defp docs do
    [
      main: "readme",
      extras: ["README.md", "CHANGELOG.md"],
      source_url: @source_url,
      source_ref: "v#{@version}"
    ]
  end
end
