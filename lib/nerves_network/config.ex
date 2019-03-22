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

  @spec drop(Types.ifname, atom) :: {:ok, {old :: map, new ::map}}
  def drop(iface, priority \\ @priority) do
    GenServer.call(__MODULE__, {:drop, iface, priority})
  end

  def init([]) do
    Logger.debug fn -> "#{__MODULE__}: init([])" end
    # If we enable hysteresis we will drop updates that
    # are needed to setup ipv4 and ipv6
    SR.register(min_interval: 500)
    defaults =
      Application.get_env(:nerves_network, :default, [])

    Logger.debug fn -> "#{__MODULE__}: defaults = #{inspect defaults}" end

    Process.send_after(self(), {:setup_default_ifaces, defaults}, 0)
    {:ok, %{}}
  end

  def handle_info({:setup_default_ifaces, defaults}, state) do
    Enum.each(defaults, fn({iface, config}) ->
      scope(iface)
         |> SR.update(config, priority: :default)
    end)
    {:noreply, state}
  end

  def handle_call({:put, iface, config, priority}, _from, state) do
    r = do_put(iface, config, priority)
    {:reply, r, state}
  end

  def handle_call({:drop, iface, priority}, _from, state) do
    r =
      scope(iface)
      |> SR.delete(priority: priority)

    {:reply, r, state}
  end

  def handle_info({:system_registry, :global, registry}, s) do
    # The registry is HUGE.  Do not inspect unless its necessary
    #Logger.debug fn -> "++++ handle_info: registry = #{inspect registry}; s = #{inspect s}" end
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

    Enum.each(modified, fn {iface, settings} ->
      # TODO(Connor): Maybe we should define a behaviour for
      # Config changes for each of the managers?

      # Don't match on teardown since it might not actually be up yet.
      IFSupervisor.teardown(iface)
      {:ok, _} = IFSupervisor.setup(iface, Enum.into(settings, []))
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

  defp do_put(iface, config, priority) do
    scope(iface)
    |> SR.update(config, priority: priority)
  end
end
