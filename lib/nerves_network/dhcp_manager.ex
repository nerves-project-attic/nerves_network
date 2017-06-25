defmodule Nerves.Network.DHCPManager do
  use GenServer
  require Logger
  import Nerves.Network.Utils

  @moduledoc false

  # The current state machine state is called "context" to avoid confusion between server
  # state and state machine state.
  defstruct context: :removed,
            ifname: nil,
            settings: nil,
            dhcp_pid: nil,
            dhcp_retry_interval: 10_000,
            dhcp_retry_timer: nil

  def start_link(ifname, settings, opts \\ []) do
    GenServer.start_link(__MODULE__, {ifname, settings}, opts)
  end

  # defmodule EventHandler do
  #   use GenServer
  #
  #   @moduledoc false
  #
  #   def start_link(opts) do
  #     GenServer.start_link(__MODULE__, opts)
  #   end
  #
  #   def init({manager, ifname}) do
  #     {:ok, %{manager: manager, ifname: ifname}}
  #   end
  #
  #
  # end

  def init({ifname, settings}) do
    # Make sure that the interface is enabled or nothing will work.
    Logger.info "DHCPManager(#{ifname}) starting"

    # Register for nerves_network_interface and udhcpc events
    {:ok, _} = Registry.register(Nerves.NetworkInterface, ifname, [])
    {:ok, _} = Registry.register(Nerves.Udhcpc, ifname, [])

    state = %Nerves.Network.DHCPManager{settings: settings, ifname: ifname}
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

  def handle_event({Nerves.NetworkInterface, :ifadded, %{ifname: ifname}}) do
    Logger.info "DHCPManager.EventHandler(#{ifname}) ifadded"
    :ifadded
  end
  # :ifmoved occurs on systems that assign stable names to removable
  # interfaces. I.e. the interface is added under the dynamically chosen
  # name and then quickly renamed to something that is stable across boots.
  def handle_event({Nerves.NetworkInterface, :ifmoved, %{ifname: ifname}}) do
    Logger.info "DHCPManager.EventHandler(#{ifname}) ifadded (moved)"
    :ifadded
  end
  def handle_event({Nerves.NetworkInterface, :ifremoved, %{ifname: ifname}}) do
    Logger.info "DHCPManager.EventHandler(#{ifname}) ifremoved"
    :ifremoved
  end

  # Filter out ifup and ifdown events
  # :is_up reports whether the interface is enabled or disabled (like by the wifi kill switch)
  # :is_lower_up reports whether the interface as associated with an AP
  def handle_event({Nerves.NetworkInterface, :ifchanged, %{ifname: ifname, is_lower_up: true}}) do
    Logger.info "DHCPManager.EventHandler(#{ifname}) ifup"
    :ifup
  end
  def handle_event({Nerves.NetworkInterface, :ifchanged, %{ifname: ifname, is_lower_up: false}}) do
    Logger.info "DHCPManager.EventHandler(#{ifname}) ifdown"
    :ifdown
  end

  # # DHCP events
  # # :bound, :renew, :deconfig, :nak


  def handle_event({Nerves.NetworkInterface, event, %{ifname: ifname}}) do
    Logger.info "DHCPManager.EventHandler(#{ifname}): ignoring event: #{inspect event}"
    :noop
  end

  def handle_info({Nerves.NetworkInterface, _, ifstate} = event, %{ifname: ifname} = s) do
    event = handle_event(event)
    scope(ifname) |> SystemRegistry.update(ifstate)
    s = consume(s.context, event, s)
    Logger.info "DHCPManager(#{s.ifname}, #{s.context}) got event #{inspect event}"
    {:noreply, s}
  end

  def handle_info({Nerves.Udhcpc, event, info}, %{ifname: ifname} = s) do
    Logger.info "DHCPManager.EventHandler(#{s.ifname}) udhcpc #{inspect event}"
    scope(ifname) |> SystemRegistry.update(info)
    s = consume(s.context, {event, info}, s)
    {:noreply, s}
  end

  def handle_info(:dhcp_retry, s) do
    s = consume(s.context, :dhcp_retry, s)
    {:noreply, s}
  end

  def handle_info(event, s) do
    Logger.info "DHCPManager.EventHandler(#{s.ifname}): ignoring event: #{inspect event}"
    {:noreply, s}
  end

  ## State machine implementation
  defp goto_context(state, newcontext) do
    %Nerves.Network.DHCPManager{state | context: newcontext}
  end

  defp consume(_, :noop, state), do: state
  ## Context: :removed
  defp consume(:removed, :ifadded, state) do
    case Nerves.NetworkInterface.ifup(state.ifname) do
      :ok ->
        {:ok, status} = Nerves.NetworkInterface.status state.ifname
        notify(Nerves.NetworkInterface, state.ifname, :ifchanged, status)

        state
          |> goto_context(:down)
      {:error, _} ->
        # The interface isn't quite up yet. Retry
        Process.send_after self(), :retry_ifadded, 250
        state
          |> goto_context(:retry_add)
    end
  end
  defp consume(:removed, :retry_ifadded, state), do: state
  defp consume(:removed, :ifdown, state), do: state

  ## Context: :retry_add
  defp consume(:retry_add, :ifremoved, state) do
    state
      |> goto_context(:removed)
  end
  defp consume(:retry_add, :retry_ifadded, state) do
    {:ok, status} = Nerves.NetworkInterface.status(state.ifname)
    notify(Nerves.NetworkInterface, state.ifname, :ifchanged, status)

    state
      |> goto_context(:down)
  end

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
  defp consume(:up, {:leasefail, _info}, state), do: state

  defp stop_udhcpc(state) do
    if is_pid(state.dhcp_pid) do
      Nerves.Network.Udhcpc.stop(state.dhcp_pid)
      %Nerves.Network.DHCPManager{state | dhcp_pid: nil}
    else
      state
    end
  end
  defp start_udhcpc(state) do
    state = stop_udhcpc(state)
    {:ok, pid} = Nerves.Network.Udhcpc.start_link(state.ifname)
    %Nerves.Network.DHCPManager{state | dhcp_pid: pid}
  end

  defp start_link_local(state) do
    {:ok, ifsettings} = Nerves.NetworkInterface.status(state.ifname)
    case Map.get(ifsettings, :ipv4_address) do
      nil ->
        ip = generate_link_local(ifsettings.mac_address)
        configure(state, [ipv4_address: ip])
      _ -> state
    end

  end

  defp configure(state, info) do
    :ok = Nerves.NetworkInterface.setup(state.ifname, info)
    :ok = Nerves.Network.Resolvconf.setup(Nerves.Network.Resolvconf, state.ifname, info)
    state
  end

  defp deconfigure(state) do
    :ok = Nerves.Network.Resolvconf.clear(Nerves.Network.Resolvconf, state.ifname)
    state
  end

end
