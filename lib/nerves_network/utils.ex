defmodule Nerves.Network.Utils do
  @moduledoc false
  @scope [:state, :network_interface]

  def notify(registry, key, notif, data) do
    Registry.dispatch(registry, key, fn entries ->
      for {pid, _} <- entries, do: send(pid, {registry, notif, data})
    end)
  end

  def generate_link_local(mac_address) do
    <<x, y, _rest :: bytes>> = :crypto.hash(:md5, mac_address)
    x =
      case x do
        255 -> 254
        0 -> 1
        v -> v
      end
    "169.254.#{x}.#{y}"
  end

  def scope(iface, append \\ []) do
    @scope ++ [iface | append]
  end
end
