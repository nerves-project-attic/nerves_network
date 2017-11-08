defmodule Nerves.Network.DHCPManager do
  use GenServer
  require Logger
  import Nerves.Network.Utils
  alias Nerves.Network.Types

  @moduledoc false

  defstruct context: :removed,
            ifname: nil,
            settings: nil,
            dhcp_pid: nil,
            dhcp_retry_interval: 60_000,
            dhcp_retry_timer: nil

  @typedoc "Settings for starting the server."
  @type dhcp_settings :: Nerves.Network.setup_settings

  @typep context :: Types.interface_context | :dhcp | :dhcp_retry

  @typedoc """
  The current state machine state is called "context" to avoid confusion between server
  state and state machine state.
  """
  @type t :: %__MODULE__{
    context: context,
    ifname: Types.ifname | nil,
    settings: dhcp_settings,
    dhcp_pid: GenServer.server() | nil,
    dhcp_retry_interval: integer,
    dhcp_retry_timer: reference
  }

  @doc false
  @spec start_link(Types.ifname, dhcp_settings, GenServer.options) :: GenServer.on_start
  def start_link(ifname, settings, opts \\ []) do
    Logger.debug fn -> "DHCPManager starting.... ifname: #{inspect ifname}; settings: #{inspect settings}" end
    GenServer.start_link(__MODULE__, {ifname, settings}, opts)
  end

  def init({ifname, settings}) do
    # Register for nerves_network_interface and udhcpc events
    {:ok, _} = Registry.register(Nerves.NetworkInterface, ifname, [])
    {:ok, _} = Registry.register(Nerves.Udhcpc, ifname, [])

    state = %Nerves.Network.DHCPManager{settings: settings, ifname: ifname}
    Logger.debug fn -> "#{__MODULE__}: initialising.... state: #{inspect state}" end
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

  @spec handle_registry_event({Nerves.NetworkInterface, atom, %{ifname: Types.ifname}}) :: Types.ifevent
  defp handle_registry_event({Nerves.NetworkInterface, :ifadded, %{ifname: ifname}}) do
    Logger.debug "DHCPManager(#{ifname}) network_interface ifadded"
    :ifadded
  end

  # :ifmoved occurs on systems that assign stable names to removable
  # interfaces. I.e. the interface is added under the dynamically chosen
  # name and then quickly renamed to something that is stable across boots.
  defp handle_registry_event({Nerves.NetworkInterface, :ifmoved, %{ifname: ifname}}) do
    Logger.debug "DHCPManager(#{ifname}) network_interface ifadded (moved)"
    :ifadded
  end

  defp handle_registry_event({Nerves.NetworkInterface, :ifremoved, %{ifname: ifname}}) do
    Logger.debug "DHCPManager(#{ifname}) network_interface ifremoved"
    :ifremoved
  end

  # Filter out ifup and ifdown events
  # :is_up reports whether the interface is enabled or disabled (like by the wifi kill switch)
  # :is_lower_up reports whether the interface as associated with an AP
  defp handle_registry_event({Nerves.NetworkInterface, :ifchanged, %{ifname: ifname, is_lower_up: true}}) do
    Logger.debug "DHCPManager(#{ifname}) network_interface ifup"
    :ifup
  end

  defp handle_registry_event({Nerves.NetworkInterface, :ifchanged, %{ifname: ifname, is_lower_up: false}}) do
    Logger.debug "DHCPManager(#{ifname}) network_interface ifdown"
    :ifdown
  end

  defp handle_registry_event({Nerves.NetworkInterface, event, %{ifname: ifname}}) do
    Logger.debug "DHCPManager(#{ifname}): ignoring event: #{inspect event}"
    :noop
  end

  defp handle_registry_event({Nerves.Udhcpc, :bound, %{ifname: ifname} = info}) do
    Logger.info "WiFiManager(#{ifname}): udhcp bound"
    {:bound, info}
  end

  defp handle_registry_event({Nerves.Udhcpc, :deconfig, %{ifname: ifname} = info}) do
    Logger.info "WiFiManager(#{ifname}): udhcp deconfig"
    {:deconfig, info}
  end

  defp handle_registry_event({Nerves.Udhcpc, :nak, %{ifname: ifname} = info}) do
    Logger.info "WiFiManager(#{ifname}): udhcp nak"
    {:nak, info}
  end

  defp handle_registry_event({Nerves.Udhcpc, :renew, %{ifname: ifname} = info}) do
    Logger.info "WiFiManager(#{ifname}): udhcp renew"
    {:renew, info}
  end

  defp handle_registry_event({Nerves.Udhcpc, event, %{ifname: ifname}}) do
    Logger.info "WiFiManager(#{ifname}): ignoring event: #{inspect event}"
    :noop
  end

  # Handle Network Interface events coming in from SystemRegistry.
  def handle_info({Nerves.NetworkInterface, _, ifstate} = event, %{ifname: ifname} = s) do
    event = handle_registry_event(event)
    scope(ifname) |> SystemRegistry.update(ifstate)
    s = consume(s.context, event, s)
    Logger.debug "DHCPManager(#{s.ifname}, #{s.context}) got event #{inspect event}"
    {:noreply, s}
  end

  # Handle Udhcpc events coming from SystemRegistry.
  def handle_info({Nerves.Udhcpc, event, info}, %{ifname: ifname} = s) do
    Logger.debug "DHCPManager(#{s.ifname}) udhcpc #{inspect event}"
    scope(ifname) |> SystemRegistry.update(info)
    s = consume(s.context, {event, info}, s)
    {:noreply, s}
  end

  # Comes from the timer.
  def handle_info(:dhcp_retry, s) do
    s = consume(s.context, :dhcp_retry, s)
    {:noreply, s}
  end

  # Catch all.
  def handle_info(event, s) do
    Logger.debug "DHCPManager(#{s.ifname}): ignoring event: #{inspect event}"
    {:noreply, s}
  end

  ## State machine implementation
  @spec goto_context(t, context) :: t
  defp goto_context(state, newcontext) do
    %Nerves.Network.DHCPManager{state | context: newcontext}
  end

  @typedoc "Event for the state machine."
  @type event :: Types.ifevent | Nerves.Network.Udhcpc.event

  @spec consume(context, event, t) :: t
  defp consume(_, :noop, state), do: state

  ## Context: :removed
  defp consume(:removed, :ifadded, state) do
    :ok = Nerves.NetworkInterface.ifup(state.ifname)

    {:ok, status} = Nerves.NetworkInterface.status state.ifname
    notify(Nerves.NetworkInterface, state.ifname, :ifchanged, status)

    state |> goto_context(:down)
  end

  defp consume(:removed, :ifdown, state), do: state

  ## Context: :down
  defp consume(:down, :ifadded, state), do: state

  defp consume(:down, :ifup, state) do
    state
      |> start_udhcpc
      |> goto_context(:dhcp)
  end

  defp consume(:down, :ifdown, state) do
    state
      |> stop_udhcpc
  end

  defp consume(:down, :ifremoved, state) do
    state
      |> stop_udhcpc
      |> goto_context(:removed)
  end

  ## Context: :dhcp
  defp consume(:dhcp, :ifup, state), do: state

  defp consume(:dhcp, {:deconfig, _info}, state), do: state

  defp consume(:dhcp, {:bound, info}, state) do
    state
      |> configure(info)
      |> goto_context(:up)
  end

  defp consume(:dhcp, {:leasefail, _info}, state) do
    dhcp_retry_timer = Process.send_after(self(), :dhcp_retry, state.dhcp_retry_interval)
    %{state | dhcp_retry_timer: dhcp_retry_timer}
      |> stop_udhcpc
      |> start_link_local
      |> goto_context(:up)
  end

  defp consume(:dhcp, :ifdown, state) do
    state
      |> stop_udhcpc
      |> goto_context(:down)
  end

  ## Context: :up
  defp consume(:up, :ifup, state), do: state

  defp consume(:up, :dhcp_retry, state) do
    state
      |> start_udhcpc
      |> goto_context(:dhcp)
  end

  defp consume(:up, :ifdown, state) do
    state
      |> stop_udhcpc
      |> deconfigure
      |> goto_context(:down)
  end

  defp consume(:up, {:renew, info}, state) do
    state
    |> configure(info)

    {:ok, status} = Nerves.NetworkInterface.status(state.ifname)
    notify(Nerves.NetworkInterface, state.ifname, :ifchanged, status)
    state
  end

  defp consume(:up, {:leasefail, _info}, state), do: state

  # Catch-all handler for consume
  defp consume(context, event, state) do
    Logger.warn "Unhandled event #{inspect event} for context #{inspect context} in consume/3."
    state
  end

  @spec stop_udhcpc(t) :: t
  defp stop_udhcpc(state) do
    if is_pid(state.dhcp_pid) do
      Nerves.Network.Udhcpc.stop(state.dhcp_pid)
      %Nerves.Network.DHCPManager{state | dhcp_pid: nil}
    else
      state
    end
  end

  @spec start_udhcpc(t) :: t
  defp start_udhcpc(state) do
    state = stop_udhcpc(state)
    {:ok, pid} = Nerves.Network.Udhcpc.start_link(state.ifname)
    %Nerves.Network.DHCPManager{state | dhcp_pid: pid}
  end

  defp start_link_local(state) do
    {:ok, ifsettings} = Nerves.NetworkInterface.status(state.ifname)
    ip = generate_link_local(ifsettings.mac_address)
    scope(state.ifname)
    |> SystemRegistry.update(%{ipv4_address: ip})
    :ok = Nerves.NetworkInterface.setup(state.ifname, [ipv4_address: ip])
    state
  end

  @spec configure(t, Types.udhcp_info) :: t
  defp configure(state, info) do
    Logger.debug("DHCP state #{inspect state} #{inspect info}")

    :ok = Nerves.NetworkInterface.setup(state.ifname, info)
    :ok = Nerves.Network.Resolvconf.setup(Nerves.Network.Resolvconf, state.ifname, info)
    state
  end

  @spec deconfigure(t) :: t
  defp deconfigure(state) do
    :ok = Nerves.Network.Resolvconf.clear(Nerves.Network.Resolvconf, state.ifname)
    state
  end

end
