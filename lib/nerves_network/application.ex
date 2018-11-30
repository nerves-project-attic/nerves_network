defmodule Nerves.Network.Application do
  @moduledoc false

  use Application

  def start(_type, _args) do
    import Supervisor.Spec, warn: false

    [resolvconf_file: resolvconf_file] = Application.get_env(:nerves_network, :resolver, [])
    [ipv4: 
     [
       lease_file: _lf,
       pid_file: _pf,
       config_file: dhclientv4_config_file
     ]
    ] = Application.get_env(:nerves_network, :dhclientv4, [])

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
