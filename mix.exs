defmodule Nerves.Network.Mixfile do
  use Mix.Project

  def project do
    [
      app: :nerves_network,
      version: "0.3.7-rc0",
      elixir: "~> 1.4",
      build_embedded: Mix.env() == :prod,
      start_permanent: Mix.env() == :prod,
      compilers: [:elixir_make] ++ Mix.compilers(),
      make_clean: ["clean"],
      deps: deps(),
      docs: [extras: ["README.md"] ++ Path.wildcard("docs/*.md")],
      package: package(),
      description: description()
    ]
  end

  # Configuration for the OTP application
  #
  # Type `mix help compile.app` for more information
  def application do
    [extra_applications: [:logger], mod: {Nerves.Network.Application, []}]
  end

  defp description do
    """
    Manage network connections.
    """
  end

  defp package do
    %{
      files: [
        "lib",
        "src/*.[ch]",
        "test",
        "mix.exs",
        "README.md",
        "LICENSE",
        "CHANGELOG.md",
        "Makefile",
        "docs/*.md"
      ],
      maintainers: ["Frank Hunleth", "Justin Schneck", "Connor Rigby"],
      licenses: ["Apache-2.0"],
      links: %{"GitHub" => "https://github.com/nerves-project/nerves_network"}
    }
  end

  defp deps do
    [
      {:system_registry, "~> 0.7"},
      {:nerves_network_interface, "~> 0.4.4"},
      {:nerves_wpa_supplicant, "~> 0.3.2"},
      {:elixir_make, "~> 0.4", runtime: false},
      {:ex_doc, "~> 0.18.0", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 0.5.1", only: [:dev, :test], runtime: false}
    ]
  end
end
