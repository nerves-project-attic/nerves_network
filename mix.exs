defmodule Nerves.InterimWiFi.Mixfile do
  use Mix.Project

  def project do
    [app: :nerves_interim_wifi,
     version: "0.1.1",
     elixir: "~> 1.2",
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
  # Type "mix help compile.app" for more information
  def application do
    [applications: [:logger, :nerves_network_interface, :nerves_wpa_supplicant],
     mod: {Nerves.InterimWiFi, []}]
  end

  defp description do
    """
    Manage WiFi network connections.
    """
  end

  defp package do
    %{files: ["lib", "src/*.[ch]", "test", "mix.exs", "README.md", "LICENSE", "CHANGELOG.md", "Makefile"],
      maintainers: ["Frank Hunleth"],
      licenses: ["Apache-2.0"],
      links: %{"GitHub" => "https://github.com/nerves-project/nerves_interim_wifi"}}
  end

  defp deps do
    [
      {:elixir_make, "~> 0.3"},
      {:earmark, "~> 1.0", only: :dev},
      {:ex_doc, "~> 0.11", only: :dev},
      {:credo, "~> 0.3", only: [:dev, :test]},
      {:nerves_network_interface, "~> 0.3.1"},
      {:nerves_wpa_supplicant, "~> 0.2.2"}
    ]
  end
end
