use Mix.Config

config :system_registry, SystemRegistry.Processor.Config,
  priorities: [
    :debug,
    :nerves_network
  ]
