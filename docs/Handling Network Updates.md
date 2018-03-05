# Handling Network Updates
For a more complete example, see the [official example](https://github.com/nerves-project/nerves_examples/tree/master/hello_network).
Here is an example of how to manage a network interface.
You can look [here](https://hexdocs.pm/nerves_network_interface/Nerves.NetworkInterface.Worker.html#t:status/0)
for all of the possible fields that you will get info for.

```elixir
defmodule MyApp.NetworkManager do
  use GenServer
  require Logger

  alias Nerves.NetworkInterface
  alias Nerves.Network

  @scope [:state, :network_interface]

  @doc "Start Networking on an interface."
  def start_link(iface) do
    GenServer.start_link(__MODULE__, [iface], [name: name(iface)])
  end

  # GenServer callbacks

  def init([iface]) do
    # In case our server starts before your driver is up and running.
    wait_until_iface_up(iface)

    # This is what causes us to get Networking events.
    SystemRegistry.register()
    {:ok, %{iface: iface, current_address: nil}}
  end

  def handle_info({:system_registry, :global, registry}, %{iface: iface, current_address: current} = state) do
    # See https://hexdocs.pm/nerves_network_interface/Nerves.NetworkInterface.Worker.html#t:status/0
    # for more info on what fields you will have here.
    scope = scope(iface, [:ipv4_address])
    ip = get_in(registry, scope)

    if ip != current do
      # Do anything you want now that your address has changed.
      # We are just logging the change.
      Logger.debug "IP Address Changed to #{ip}"
      {:noreply, %{state | current_address: ip}}
    else
      {:noreply, state}
    end
  end

  # Private

  defp name(iface), do: Module.concat(__MODULE__, iface)

  defp scope(iface, append) do
    @scope ++ [iface] ++ append
  end

  # This should probably have some error checking.
  defp wait_until_iface_up(iface) do
    unless iface in NetworkInterface.interfaces() do
      Process.sleep(500)
      wait_until_iface_up(iface)
    end
  end
end
```
