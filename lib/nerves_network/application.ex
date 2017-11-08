defmodule Nerves.Network.Application do
  @moduledoc false

  use Application

  def start(_type, _args) do
    import Supervisor.Spec, warn: false

    children = [
      supervisor(Registry, [:duplicate, Nerves.Udhcpc], id: Nerves.Udhcpc),
      supervisor(Registry, [:duplicate, Nerves.Dhclient], id: Nerves.Dhclient),
      worker(Nerves.Network.Resolvconf, ["/tmp/resolv.conf", [name: Nerves.Network.Resolvconf]]),
      supervisor(Nerves.Network.IFSupervisor, [[name: Nerves.Network.IFSupervisor]]),
      worker(Nerves.Network.Config, []),
    ]

    opts = [strategy: :rest_for_one, name: Nerves.Network.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
