defmodule Nerves.Network.Config  do
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

  @spec put(Types.ifname, Nerves.Network.setup_settings, atom) :: {:ok, {old :: map, new ::map}}
  def put(iface, config, priority \\ @priority) do
    scope(iface)
    |> SR.update(config, [priority: priority])
  end

  @spec drop(Types.ifname, atom) :: {:ok, {old :: map, new ::map}}
  def drop(iface, priority \\ @priority) do
    scope(iface)
    |> SR.delete(priority: priority)
  end

  def init([]) do
    Logger.debug fn -> "#{__MODULE__}: init([])" end
    SR.register
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

  def handle_info({:system_registry, :global, registry}, s) do
    Logger.debug fn -> "++++ handle_info: registry = #{inspect registry}; s = #{inspect s}" end
    net_config = get_in(registry, @scope) || %{}
    s = update(net_config, s)
    {:noreply, s}
  end

  def update(old, old, _) do
    Logger.debug fn -> "#{__MODULE__}: update old**2 = #{inspect old}" end
    {old, []}
  end

  def update(new, old) do
    Logger.debug fn -> "#{__MODULE__}: update new = #{inspect new}" end
    Logger.debug fn -> "#{__MODULE__}: update old = #{inspect old}" end
    {added, removed, modified} =
      changes(new, old)

    removed = Enum.map(removed, fn({k, _}) -> {k, %{}} end)
    modified = added ++ modified

    Logger.debug fn -> "#{__MODULE__}: modified = #{inspect modified}" end
    Enum.each(modified, fn({iface, settings}) ->
      IFSupervisor.setup(iface, settings)
    end)

    Logger.debug fn -> "#{__MODULE__}: removed = #{inspect removed}" end
    Enum.each(removed, fn({iface, _settings}) ->
      IFSupervisor.teardown(iface)
    end)
    new
  end

  @spec scope(Types.ifname, append :: SR.scope) :: SR.scope
  defp scope(iface, append \\ []) do
    @scope ++ [iface | append]
  end

  defp changes(new, old) do
    Logger.debug fn -> "#{__MODULE__}: changes new = #{inspect new}" end
    Logger.debug fn -> "#{__MODULE__}: changes old = #{inspect old}" end
    added =
      Enum.filter(new, fn({k, _}) -> Map.get(old, k) == nil end)
    removed =
      Enum.filter(old, fn({k, _}) -> Map.get(new, k) == nil end)
    modified =
      Enum.filter(new, fn({k, v}) ->
        val = Map.get(old, k)
        val != nil and val != v
      end)
    {added, removed, modified}
  end
end
