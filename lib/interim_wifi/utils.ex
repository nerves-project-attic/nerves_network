defmodule Nerves.InterimWiFi.Utils do
  @scope [:state, :network_interface]

  def notify(registry, key, notif, data) do
    Registry.dispatch(registry, key, fn entries ->
      for {pid, _} <- entries, do: send(pid, {registry, notif, data})
    end)
  end
  
  def scope(iface, append \\ []) do
    @scope ++ [iface | append]
  end
end
