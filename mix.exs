defmodule Nerves.Network.Mixfile do
  use Mix.Project

  def project do
    [
      app: :nerves_network,
      version: "0.5.4",
      elixir: "~> 1.4",
      start_permanent: Mix.env() == :prod,
      build_embedded: true,
      compilers: [:elixir_make | Mix.compilers()],
      make_targets: ["all"],
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
      licenses: ["Apache-2.0"],
      links: %{"GitHub" => "https://github.com/nerves-project/nerves_network"}
    }
  end

  defp deps do
    [
      {:system_registry, "~> 0.7"},
      {:nerves_network_interface, "~> 0.4.4"},
      {:nerves_wpa_supplicant, "~> 0.5"},
      {:one_dhcpd, "~> 0.2.0"},
      {:elixir_make, "~> 0.5", runtime: false},
      {:ex_doc, "~> 0.19", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 0.5.1", only: [:dev, :test], runtime: false}
    ]
  end
end
