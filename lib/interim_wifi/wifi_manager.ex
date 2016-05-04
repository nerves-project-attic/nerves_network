defmodule Nerves.InterimWiFi.WiFiManager do
  use GenServer
  require Logger

  # The current state machine state is called "context" to avoid confusion between server
  # state and state machine state.
  defstruct context: :down,
            ifname: nil,
            settings: nil,
            dhcp_pid: nil,
            wpa_pid: nil

  def start_link(ifname, settings, opts \\ []) do
    GenServer.start_link(__MODULE__, {ifname, settings}, opts)
  end

  defmodule EventHandler do
    use GenEvent

    def init({manager, ifname}) do
      {:ok, %{manager: manager, ifname: ifname}}
    end

    # Filter out ifup and ifdown events
    # :is_up reports whether the interface is enabled or disabled (like by the wifi kill switch)
    # :is_lower_up reports whether the interface as associated with an AP
    def handle_event({:net_basic, _, :ifchanged, %{:ifname => ifname, :is_up => true}}, %{:ifname => ifname} = state) do
      Logger.info "WiFiManager.EventHandler(#{state.ifname}) ifup"
      send state.manager, :ifup
      {:ok, state}
    end
    def handle_event({:net_basic, _, :ifchanged, %{:ifname => ifname, :is_up => false}}, %{:ifname => ifname} = state) do
      Logger.info "WiFiManager.EventHandler(#{ifname}) ifdown"
      send state.manager, :ifdown
      {:ok, state}
    end

    # wpa_supplicant events
    def handle_event({:wpa_supplicant, _, :"CTRL-EVENT-CONNECTED"}, state) do
      Logger.info "WiFiManager.EventHandler(#{state.ifname}) wifi_connected"
      send state.manager, :wifi_connected
      {:ok, state}
    end
    def handle_event({:wpa_supplicant, _, :"CTRL-EVENT-DISCONNECTED"}, state) do
      Logger.info "WiFiManager.EventHandler(#{state.ifname}) wifi_disconnected"
      send state.manager, :wifi_disconnected
      {:ok, state}
    end

    # DHCP events
    # :bound, :renew, :deconfig, :nak
    def handle_event({:udhcpc, _, event, %{:ifname => ifname} = info}, %{:ifname => ifname} = state) do
      Logger.info "WiFiManager.EventHandler(#{state.ifname}) udhcpc #{inspect event}"
      send state.manager, {event, info}
      {:ok, state}
    end

    def handle_event(event, state) do
      Logger.info "WiFiManager.EventHandler(#{state.ifname}): ignoring event: #{inspect event}"
      {:ok, state}
    end
  end

  def init({ifname, settings}) do
    # Make sure that the interface is enabled or nothing will work.
    Logger.info "WiFiManager(#{ifname}) starting"
    :ok = NetBasic.ifup(Nerves.InterimWiFi.NetBasic, ifname)

    # Register for net_basic events
    GenEvent.add_handler(Nerves.InterimWiFi.EventManager, EventHandler, {self, ifname})

    state = %Nerves.InterimWiFi.WiFiManager{settings: settings, ifname: ifname}

    # Check the status and send an initial event through based
    # on whether the interface is up or down
    # NOTE: GenEvent.notify/2 is asynchronous which is good and bad. It's
    #       good since if it were synchronous, we'd certainly mess up our state.
    #       It's bad since there's a race condition between when we get the status
    #       and when the update is sent. I can't imagine us hitting the race condition
    #       though. :)
    status = NetBasic.status(Nerves.InterimWiFi.NetBasic, ifname)
    GenEvent.notify(Nerves.InterimWiFi.EventManager, {:net_basic, Nerves.InterimWiFi.NetBasic, :ifchanged, status})

    {:ok, state}
  end

  def handle_info(event, state) do
    Logger.info "WifiManager(#{state.ifname}, #{state.context}) got event #{inspect event}"
    state = consume(state.context, event, state)
    {:noreply, state}
  end

  ## State machine implementation
  defp goto_context(state, newcontext) do
    %Nerves.InterimWiFi.WiFiManager{state | context: newcontext}
  end

  ## Context: :down
  defp consume(:down, :ifup, state) do
    state
      |> start_wpa
      |> goto_context(:associate_wifi)
  end
  defp consume(:down, :ifdown, state) do
    state
      |> stop_udhcpc
      |> stop_wpa
  end

  ## Context: :associate_wifi
  defp consume(:associate_wifi, :ifup, state), do: state
  defp consume(:associate_wifi, :ifdown, state) do
    state
      |> stop_wpa
      |> goto_context(:ifdown)
  end
  defp consume(:associate_wifi, :wifi_connected, state) do
    state
      |> start_udhcpc
      |> goto_context(:dhcp)
  end
  defp consume(:associate_wifi, :wifi_disconnected, state), do: state

  ## Context: :dhcp
  defp consume(:dhcp, :ifup, state), do: state
  defp consume(:dhcp, {:deconfig, _info}, state), do: state
  defp consume(:dhcp, {:bound, info}, state) do
    state
      |> configure(info)
      |> goto_context(:up)
  end
  defp consume(:dhcp, :ifdown, state) do
    state
      |> stop_udhcpc
      |> goto_context(:down)
  end
  defp consume(:dhcp, :wifi_disconnected, state) do
    state
      |> stop_udhcpc
      |> goto_context(:associate_wifi)
  end

  ## Context: :up
  defp consume(:up, :ifup, state), do: state
  defp consume(:up, :ifdown, state) do
    state
      |> stop_udhcpc
      |> deconfigure
      |> goto_context(:down)
  end
  defp consume(:up, :wifi_disconnected, state) do
    state
      |> stop_udhcpc
      |> goto_context(:associate_wifi)
  end

  ## Context: :wait_for_retry
  defp consume(:wait_for_retry, :ifup, state), do: state
  defp consume(:wait_for_retry, :ifdown, state) do
    state
      |> stop_udhcpc
      |> goto_context(:down)
  end

  defp stop_wpa(state) do
    if is_pid(state.wpa_pid) do
      WpaSupplicant.stop(state.wpa_pid)
      %Nerves.InterimWiFi.WiFiManager{state | wpa_pid: nil}
    else
      state
    end
  end
  defp start_wpa(state) do
    state = stop_wpa(state)
    {:ok, pid} = WpaSupplicant.start_link("/var/run/wpa_supplicant/#{state.ifname}",
                                          Nerves.InterimWiFi.EventManager)
    wpa_supplicant_settings = Map.new(state.settings)
    :ok = WpaSupplicant.set_network(pid, wpa_supplicant_settings)
    %Nerves.InterimWiFi.WiFiManager{state | wpa_pid: pid}
  end

  defp stop_udhcpc(state) do
    if is_pid(state.dhcp_pid) do
      Nerves.InterimWiFi.Udhcpc.stop(state.dhcp_pid)
      %Nerves.InterimWiFi.WiFiManager{state | dhcp_pid: nil}
    else
      state
    end
  end
  defp start_udhcpc(state) do
    state = stop_udhcpc(state)
    {:ok, pid} = Nerves.InterimWiFi.Udhcpc.start_link(state.ifname)
    %Nerves.InterimWiFi.WiFiManager{state | dhcp_pid: pid}
  end

  defp configure(state, info) do
    :ok = NetBasic.set_config(Nerves.InterimWiFi.NetBasic, state.ifname, info)
    :ok = Resolvconf.set_config(Nerves.InterimWiFi.Resolvconf, state.ifname, info)
    state
  end

  defp deconfigure(state) do
    :ok = Resolvconf.clear(Nerves.InterimWiFi.Resolvconf, state.ifname)
    state
  end

end
