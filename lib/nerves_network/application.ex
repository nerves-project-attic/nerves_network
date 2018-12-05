defmodule Nerves.Network.Application do
  @moduledoc false

  use Application
  require Logger

  def start(_type, _args) do
    import Supervisor.Spec, warn: false

    Logger.configure level: :debug
    [resolvconf_file: resolvconf_file] = Application.get_env(:nerves_network, :resolver, [])
    [ipv4: ipv4] = Application.get_env(:nerves_network, :dhclientv4, [])

    dhclientv4_config_file = ipv4[:config_file] || Nerves.Network.Dhclientv4Conf.default_dhclient_conf_path()

    children = [
      supervisor(Registry, [:duplicate, Nerves.Dhclientv4], id: Nerves.Dhclientv4),
      supervisor(Registry, [:duplicate, Nerves.Dhclient], id: Nerves.Dhclient),
      worker(Nerves.Network.Resolvconf, [resolvconf_file, [name: Nerves.Network.Resolvconf]]),
      worker(Nerves.Network.Dhclientv4Conf, [dhclientv4_config_file, [name: Nerves.Network.Dhclientv4Conf]]),
      supervisor(Nerves.Network.IFSupervisor, [[name: Nerves.Network.IFSupervisor]]),
      worker(Nerves.Network.Config, []),
    ]

    opts = [strategy: :rest_for_one, name: Nerves.Network.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
