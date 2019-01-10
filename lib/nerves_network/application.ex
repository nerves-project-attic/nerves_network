defmodule Nerves.Network.Application do
  @moduledoc false

  use Application

  def start(_type, _args) do
    import Supervisor.Spec, warn: false

    children = [
      worker(Nerves.Network.Config, []),
      supervisor(Registry, [:duplicate, Nerves.Udhcpc]),
      worker(Nerves.Network.Resolvconf, ["/tmp/resolv.conf", [name: Nerves.Network.Resolvconf]]),
      supervisor(Nerves.Network.IFSupervisor, [[name: Nerves.Network.IFSupervisor]])
    ]

    opts = [strategy: :rest_for_one, name: Nerves.Network.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
