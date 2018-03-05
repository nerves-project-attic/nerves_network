defmodule Nerves.Network.Mixfile do
  use Mix.Project

  def project do
    [app: :nerves_network,
     version: "0.3.6",
     elixir: "~> 1.4",
     build_embedded: Mix.env == :prod,
     start_permanent: Mix.env == :prod,
     compilers: [:elixir_make] ++ Mix.compilers,
     make_clean: ["clean"],
     deps: deps(),
     docs: [extras: ["README.md"]],
     package: package(),
     description: description()
    ]
  end

  # Configuration for the OTP application
  #
  # Type `mix help compile.app` for more information
  def application do
    [extra_applications: [:logger],
     mod: {Nerves.Network.Application, []}]
  end

  defp description do
    """
    Manage network connections.
    """
  end

  defp package do
    %{files: ["lib", "src/*.[ch]", "test", "mix.exs", "README.md", "LICENSE", "CHANGELOG.md", "Makefile"],
      maintainers: ["Frank Hunleth", "Justin Schneck"],
      licenses: ["Apache-2.0"],
      links: %{"GitHub" => "https://github.com/nerves-project/nerves_network"}}
  end

  defp deps do
    [
      {:system_registry, "~> 0.4"},
      {:nerves_network_interface, "~> 0.4.0"},
      {:nerves_wpa_supplicant, "~> 0.3.0"},
      {:elixir_make, "~> 0.4", runtime: false},
      {:ex_doc, "~> 0.11", only: :dev},
      {:dialyxir, "~> 0.5", only: [:dev], runtime: false}
    ]
  end
end
