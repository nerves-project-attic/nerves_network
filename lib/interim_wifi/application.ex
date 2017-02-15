defmodule Nerves.InterimWiFi.Application do
  @moduledoc false

  use Application

  def start(_type, _args) do
    import Supervisor.Spec, warn: false

    children = [
      worker(Registry, [:duplicate, Nerves.Udhcpc], restart: :transient),
      worker(Nerves.InterimWiFi.Resolvconf, ["/tmp/resolv.conf", [name: Nerves.InterimWiFi.Resolvconf]]),
      supervisor(Nerves.InterimWiFi.IFSupervisor, [[name: Nerves.InterimWiFi.IFSupervisor]]),
    ]

    opts = [strategy: :rest_for_one, name: Nerves.InterimWiFi.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
