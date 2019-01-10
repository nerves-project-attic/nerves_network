defmodule Nerves.Network.Config do
  @moduledoc false

  use GenServer

  require Logger

  alias SystemRegistry, as: SR
  alias Nerves.Network.{IFSupervisor, Types}

  @scope [:config, :network_interface]
  @priority :nerves_network

  def start_link do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  @spec put(Types.ifname(), Nerves.Network.setup_settings(), atom) ::
          {:ok, {old :: map, new :: map}}
  def put(iface, config, priority \\ @priority) do
    GenServer.call(__MODULE__, {:put, iface, config, priority})
  end

  def drop(iface, priority \\ @priority) do
    GenServer.call(__MODULE__, {:drop, iface, priority})
  end

  def init([]) do
    SR.register()
    defaults = Application.get_env(:nerves_network, :default, [])

    Enum.each(defaults, fn {iface, config} ->
      iface
      |> to_string()
      |> put(config, :default)
    end)

    {:ok, %{}}
  end

  def handle_call({:put, iface, config, priority}, _from, state) do
    r =
      scope(iface)
      |> SR.update(config, priority: priority)

    {:reply, r, state}
  end

  def handle_call({:drop, iface, priority}, _from, state) do
    r =
      scope(iface)
      |> SR.delete(priority: priority)

    {:reply, r, state}
  end

  def handle_info({:system_registry, :global, registry}, s) do
    IO.puts("got registry")
    net_config = get_in(registry, @scope) || %{}
    s = update(net_config, s)
    {:noreply, s}
  end

  def update(old, old) do
    old
  end

  def update(new, old) do
    {added, removed, modified} = changes(new, old)
    removed = Enum.map(removed, fn {k, _} -> {k, %{}} end)
    modified = added ++ modified

    IO.inspect(modified, label: "modified")
    IO.inspect(removed, label: "removed")

    Enum.each(modified, fn {iface, settings} ->
      # TODO(Connor): Maybe we should define a behaviour for
      # Config changes for each of the managers?

      # Don't match on teardown since it might not actually be up yet.
      IFSupervisor.teardown(iface)
      {:ok, _} = IFSupervisor.setup(iface, settings)
    end)

    Enum.each(removed, fn {iface, _settings} ->
      :ok = IFSupervisor.teardown(iface)
    end)

    new
  end

  @spec scope(Types.ifname(), append :: SR.scope()) :: SR.scope()
  defp scope(iface, append \\ []) do
    @scope ++ [iface | append]
  end

  defp changes(new, old) do
    added = Enum.filter(new, fn {k, _} -> old[k] == nil end)
    removed = Enum.filter(old, fn {k, _} -> new[k] == nil end)

    modified =
      Enum.filter(new, fn {k, v} ->
        val = old[k]
        val != nil and val != v
      end)

    {added, removed, modified}
  end
end
