defmodule Nerves.Network.Application do
  @moduledoc false
  use Application
  require Logger

  def start(_type, _args) do
    import Supervisor.Spec, warn: false

    [resolvconf_file: resolvconf_file] = Application.get_env(:nerves_network, :resolver, [])
    [ipv4: ipv4] = Application.get_env(:nerves_network, :dhclientv4, [])
    [ipv6: ipv6] = Application.get_env(:nerves_network, :dhclientv6, [])

    dhclientv4_config_file = ipv4[:config_file] || Nerves.Network.DhclientConf.default_dhclient_conf_path(:ipv4)
    dhclientv6_config_file = ipv6[:config_file] || Nerves.Network.DhclientConf.default_dhclient_conf_path(:ipv6)

    children = [
      supervisor(Registry, [:duplicate, Nerves.Dhclientv4], id: Nerves.Dhclientv4),
      supervisor(Registry, [:duplicate, Nerves.Dhclient], id: Nerves.Dhclient),
      worker(Nerves.Network.Resolvconf, [resolvconf_file, [name: Nerves.Network.Resolvconf]]),
      Supervisor.child_spec({Nerves.Network.DhclientConf, [dhclientv4_config_file, [name: Nerves.Network.DhclientConf.Ipv4]]}, id: Nerves.Network.DhclientConf.Ipv4),
      Supervisor.child_spec({Nerves.Network.DhclientConf, [dhclientv6_config_file, [name: Nerves.Network.DhclientConf.Ipv6]]}, id: Nerves.Network.DhclientConf.Ipv6),
      supervisor(Nerves.Network.IFSupervisor, [[name: Nerves.Network.IFSupervisor]]),
      worker(Nerves.Network.Config, [])
    ]

    opts = [strategy: :rest_for_one, name: Nerves.Network.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
