defmodule Nerves.InterimWiFi.DHCPManager do
  use GenServer
  require Logger

  @moduledoc false

  # The current state machine state is called "context" to avoid confusion between server
  # state and state machine state.
  defstruct context: :removed,
            ifname: nil,
            settings: nil,
            dhcp_pid: nil

  def start_link(ifname, settings, opts \\ []) do
    GenServer.start_link(__MODULE__, {ifname, settings}, opts)
  end

  defmodule EventHandler do
    use GenEvent

    @moduledoc false

    def init({manager, ifname}) do
      {:ok, %{manager: manager, ifname: ifname}}
    end

    def handle_event({:nerves_network_interface, _, :ifadded, %{:ifname => ifname}}, %{:ifname => ifname} = state) do
      Logger.info "DHCPManager.EventHandler(#{state.ifname}) ifadded"
      send state.manager, :ifadded
      {:ok, state}
    end
    # :ifmoved occurs on systems that assign stable names to removable
    # interfaces. I.e. the interface is added under the dynamically chosen
    # name and then quickly renamed to something that is stable across boots.
    def handle_event({:nerves_network_interface, _, :ifmoved, %{:ifname => ifname}}, %{:ifname => ifname} = state) do
      Logger.info "DHCPManager.EventHandler(#{state.ifname}) ifadded (moved)"
      send state.manager, :ifadded
      {:ok, state}
    end
    def handle_event({:nerves_network_interface, _, :ifremoved, %{:ifname => ifname}}, %{:ifname => ifname} = state) do
      Logger.info "DHCPManager.EventHandler(#{state.ifname}) ifremoved"
      send state.manager, :ifremoved
      {:ok, state}
    end

    # Filter out ifup and ifdown events
    # :is_up reports whether the interface is enabled or disabled (like by the wifi kill switch)
    # :is_lower_up reports whether the interface as associated with an AP
    def handle_event({:nerves_network_interface, _, :ifchanged, %{:ifname => ifname, :is_lower_up => true}}, %{:ifname => ifname} = state) do
      Logger.info "DHCPManager.EventHandler(#{state.ifname}) ifup"
      send state.manager, :ifup
      {:ok, state}
    end
    def handle_event({:nerves_network_interface, _, :ifchanged, %{:ifname => ifname, :is_lower_up => false}}, %{:ifname => ifname} = state) do
      Logger.info "DHCPManager.EventHandler(#{ifname}) ifdown"
      send state.manager, :ifdown
      {:ok, state}
    end

    # DHCP events
    # :bound, :renew, :deconfig, :nak
    def handle_event({:udhcpc, _, event, %{:ifname => ifname} = info}, %{:ifname => ifname} = state) do
      Logger.info "DHCPManager.EventHandler(#{state.ifname}) udhcpc #{inspect event}"
      send state.manager, {event, info}
      {:ok, state}
    end

    def handle_event(event, state) do
      Logger.info "DHCPManager.EventHandler(#{state.ifname}): ignoring event: #{inspect event}"
      {:ok, state}
    end
  end

  def init({ifname, settings}) do
    # Make sure that the interface is enabled or nothing will work.
    Logger.info "DHCPManager(#{ifname}) starting"

    # Register for nerves_network_interface events
    GenEvent.add_handler(Nerves.NetworkInterface.event_manager, EventHandler, {self(), ifname})

    state = %Nerves.InterimWiFi.DHCPManager{settings: settings, ifname: ifname}

    # If the interface currently exists send ourselves a message that it
    # was added to get things going.
    current_interfaces = Nerves.NetworkInterface.interfaces
    if Enum.member?(current_interfaces, ifname) do
      send self(), :ifadded
    end

    {:ok, state}
  end

  def handle_info(event, state) do
    Logger.info "DHCPManager(#{state.ifname}, #{state.context}) got event #{inspect event}"
    state = consume(state.context, event, state)
    {:noreply, state}
  end

  ## State machine implementation
  defp goto_context(state, newcontext) do
    %Nerves.InterimWiFi.DHCPManager{state | context: newcontext}
  end

  ## Context: :removed
  defp consume(:removed, :ifadded, state) do
    case Nerves.NetworkInterface.ifup(state.ifname) do
      :ok ->
        # Check the status and send an initial event through based
        # on whether the interface is up or down
        # NOTE: GenEvent.notify/2 is asynchronous which is good and bad. It's
        #       good since if it were synchronous, we'd certainly mess up our state.
        #       It's bad since there's a race condition between when we get the status
        #       and when the update is sent. I can't imagine us hitting the race condition
        #       though. :)
        {:ok, status} = Nerves.NetworkInterface.status state.ifname
        GenEvent.notify(Nerves.NetworkInterface.event_manager, {:nerves_network_interface, self(), :ifchanged, status})

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

  ## Context: :retry_add
  defp consume(:retry_add, :ifremoved, state) do
    state
      |> goto_context(:removed)
  end
  defp consume(:retry_add, :retry_ifadded, state) do
    {:ok, status} = Nerves.NetworkInterface.status(state.ifname)
    GenEvent.notify(Nerves.NetworkInterface.event_manager, {:nerves_network_interface, self(), :ifchanged, status})

    state
      |> goto_context(:down)
  end

  ## Context: :down
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
  defp consume(:dhcp, {:leasefail, _info}, state), do: state
  defp consume(:dhcp, :ifdown, state) do
    state
      |> stop_udhcpc
      |> goto_context(:down)
  end

  ## Context: :up
  defp consume(:up, :ifup, state), do: state
  defp consume(:up, :ifdown, state) do
    state
      |> stop_udhcpc
      |> deconfigure
      |> goto_context(:down)
  end

  defp stop_udhcpc(state) do
    if is_pid(state.dhcp_pid) do
      Nerves.InterimWiFi.Udhcpc.stop(state.dhcp_pid)
      %Nerves.InterimWiFi.DHCPManager{state | dhcp_pid: nil}
    else
      state
    end
  end
  defp start_udhcpc(state) do
    state = stop_udhcpc(state)
    {:ok, pid} = Nerves.InterimWiFi.Udhcpc.start_link(state.ifname)
    %Nerves.InterimWiFi.DHCPManager{state | dhcp_pid: pid}
  end

  defp configure(state, info) do
    :ok = Nerves.NetworkInterface.setup(state.ifname, info)
    :ok = Nerves.InterimWiFi.Resolvconf.setup(Nerves.InterimWiFi.Resolvconf, state.ifname, info)
    state
  end

  defp deconfigure(state) do
    :ok = Nerves.InterimWiFi.Resolvconf.clear(Nerves.InterimWiFi.Resolvconf, state.ifname)
    state
  end
end
