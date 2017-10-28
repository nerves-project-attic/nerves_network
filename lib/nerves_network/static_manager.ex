defmodule Nerves.Network.StaticManager do
  @moduledoc false

  use GenServer
  import Nerves.Network.Utils
  alias Nerves.Network.Types
  require Logger

  defstruct context: :removed,
            ifname: nil,
            settings: nil

  @typep context :: Types.interface_context

  @typedoc "GenServer state."
  @type t :: %__MODULE__{
    context: context,
    ifname: Types.ifname | nil,
    settings: Nerves.Network.setup_settings | nil
  }

  @doc false
  @spec start_link(Types.ifname, Nerves.Network.setup_settings, GenServer.options) :: GenServer.on_start
  def start_link(ifname, settings, opts \\ []) do
    GenServer.start_link(__MODULE__, {ifname, settings}, opts)
  end

  def init({ifname, settings}) do
    # Make sure that the interface is enabled or nothing will work.
    Logger.info "StaticManager(#{ifname}) starting"

    # Register for nerves_network_interface events
    {:ok, _} = Registry.register(Nerves.NetworkInterface, ifname, [])

    state = %Nerves.Network.StaticManager{settings: settings, ifname: ifname}
    # If the interface currently exists send ourselves a message that it
    # was added to get things going.
    current_interfaces = Nerves.NetworkInterface.interfaces
    state =
      if Enum.member?(current_interfaces, ifname) do
        consume(state.context, :ifadded, state)
      else
        state
      end

    {:ok, state}
  end

  def handle_info({Nerves.NetworkInterface, _, ifstate} = event, %{ifname: ifname} = s) do
    event = handle_registry_event(event)
    scope(ifname) |> SystemRegistry.update(ifstate)
    s = consume(s.context, event, s)
    Logger.info "StaticManager(#{s.ifname}, #{s.context}) got event #{inspect event}"
    {:noreply, s}
  end

  @spec handle_registry_event({Nerves.NetworkInterface, atom, %{ifname: Types.ifname, is_lower_up: boolean}}) :: Types.ifevent
  defp handle_registry_event({Nerves.NetworkInterface, :ifadded, %{ifname: ifname}}) do
    Logger.info "StaticManager(#{ifname}) network_interface ifadded"
    :ifadded
  end
  # :ifmoved occurs on systems that assign stable names to removable
  # interfaces. I.e. the interface is added under the dynamically chosen
  # name and then quickly renamed to something that is stable across boots.
  defp handle_registry_event({Nerves.NetworkInterface, :ifmoved, %{ifname: ifname}}) do
    Logger.info "StaticManager(#{ifname}) network_interface ifadded (moved)"
    :ifadded
  end
  defp handle_registry_event({Nerves.NetworkInterface, :ifremoved, %{ifname: ifname}}) do
    Logger.info "StaticManager(#{ifname}) network_interface ifremoved"
    :ifremoved
  end

  # Filter out ifup and ifdown events
  # :is_up reports whether the interface is enabled or disabled (like by the wifi kill switch)
  # :is_lower_up reports whether the interface as associated with an AP
  defp handle_registry_event({Nerves.NetworkInterface, :ifchanged, %{ifname: ifname, is_lower_up: true}}) do
    Logger.info "StaticManager(#{ifname}) network_interface ifup"
    :ifup
  end
  defp handle_registry_event({Nerves.NetworkInterface, :ifchanged, %{ifname: ifname, is_lower_up: false}}) do
    Logger.info "StaticManager(#{ifname}) network_interface ifdown"
    :ifdown
  end

  defp handle_registry_event({Nerves.NetworkInterface, event, %{ifname: ifname}}) do
    Logger.info "StaticManager(#{ifname}): network_interface ignoring event: #{inspect event}"
    :noop
  end

  ## State machine implementation
  @spec goto_context(t, context) :: t
  defp goto_context(state, newcontext) do
    %Nerves.Network.StaticManager{state | context: newcontext}
  end

  @typedoc "Network event to be consumed."
  @type event :: Types.ifevent

  @spec consume(context, event, t) :: t
  defp consume(_, :noop, state), do: state

  ## Context: removed
  defp consume(:removed, :ifadded, state) do
    :ok = Nerves.NetworkInterface.ifup(state.ifname)
    {:ok, status} = Nerves.NetworkInterface.status state.ifname
    notify(Nerves.NetworkInterface, state.ifname, :ifchanged, status)

    state |> goto_context(:down)
  end

  ## Context: :down
  defp consume(:down, :ifup, state) do
    state
      |> configure
      |> goto_context(:up)
  end

  defp consume(:down, :ifdown, state), do: state

  defp consume(:down, :ifremoved, state) do
    state
      |> goto_context(:removed)
  end

  ## Context: :up
  defp consume(:up, :ifup, state), do: state

  defp consume(:up, :ifdown, state) do
    state
      |> deconfigure
      |> goto_context(:down)
  end

  defp consume(:up, :ifadded, state), do: state

  @spec configure(t) :: t
  defp configure(state) do
    :ok = Nerves.NetworkInterface.setup(state.ifname, state.settings)
    :ok = Nerves.Network.Resolvconf.setup(Nerves.Network.Resolvconf, state.ifname, state.settings)
    state
  end

  @spec deconfigure(t) :: t
  defp deconfigure(state) do
    :ok = Nerves.Network.Resolvconf.clear(Nerves.Network.Resolvconf, state.ifname)
    state
  end
end
