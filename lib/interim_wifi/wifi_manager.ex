defmodule Nerves.InterimWiFi.WiFiManager do
  use GenServer
  require Logger

  # The following are Nerves locations of the supplicant. If not using
  # Nerves, these may be different.
  @wpa_supplicant_path "/usr/sbin/wpa_supplicant"
  @wpa_control_path "/var/run/wpa_supplicant"
  @wpa_config_file "/tmp/nerves_interim_wpa.conf"

  # The current state machine state is called "context" to avoid confusion between server
  # state and state machine state.
  defstruct context: :removed,
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

    def handle_event({:net_basic, _, :ifadded, %{:ifname => ifname}}, %{:ifname => ifname} = state) do
      Logger.info "WiFiManager.EventHandler(#{state.ifname}) ifadded"
      send state.manager, :ifadded
      {:ok, state}
    end
    # :ifmoved occurs on systems that assign stable names to removable
    # interfaces. I.e. the interface is added under the dynamically chosen
    # name and then quickly renamed to something that is stable across boots.
    def handle_event({:net_basic, _, :ifmoved, %{:ifname => ifname}}, %{:ifname => ifname} = state) do
      Logger.info "WiFiManager.EventHandler(#{state.ifname}) ifadded (moved)"
      send state.manager, :ifadded
      {:ok, state}
    end
    def handle_event({:net_basic, _, :ifremoved, %{:ifname => ifname}}, %{:ifname => ifname} = state) do
      Logger.info "WiFiManager.EventHandler(#{state.ifname}) ifremoved"
      send state.manager, :ifremoved
      {:ok, state}
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
    def handle_event({:nerves_wpa_supplicant, _, :"CTRL-EVENT-CONNECTED"}, state) do
      Logger.info "WiFiManager.EventHandler(#{state.ifname}) wifi_connected"
      send state.manager, :wifi_connected
      {:ok, state}
    end
    def handle_event({:nerves_wpa_supplicant, _, :"CTRL-EVENT-DISCONNECTED"}, state) do
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

    # Register for net_basic events
    GenEvent.add_handler(Nerves.InterimWiFi.EventManager, EventHandler, {self, ifname})

    state = %Nerves.InterimWiFi.WiFiManager{settings: settings, ifname: ifname}

    # If the interface currently exists send ourselves a message that it
    # was added to get things going.
    current_interfaces = NetBasic.interfaces Nerves.InterimWiFi.NetBasic
    if Enum.member?(current_interfaces, ifname) do
      send self, :ifadded
    end

    {:ok, state}
  end

  def handle_info(event, state) do
    Logger.info "WiFiManager(#{state.ifname}, #{state.context}) got event #{inspect event}"
    state = consume(state.context, event, state)
    {:noreply, state}
  end

  ## State machine implementation
  defp goto_context(state, newcontext) do
    %Nerves.InterimWiFi.WiFiManager{state | context: newcontext}
  end

  ## Context: :removed
  defp consume(:removed, :ifadded, state) do
    case NetBasic.ifup(Nerves.InterimWiFi.NetBasic, state.ifname) do
      :ok ->
        # Check the status and send an initial event through based
        # on whether the interface is up or down
        # NOTE: GenEvent.notify/2 is asynchronous which is good and bad. It's
        #       good since if it were synchronous, we'd certainly mess up our state.
        #       It's bad since there's a race condition between when we get the status
        #       and when the update is sent. I can't imagine us hitting the race condition
        #       though. :)
        {:ok, status} = NetBasic.status(Nerves.InterimWiFi.NetBasic, state.ifname)
        GenEvent.notify(Nerves.InterimWiFi.EventManager, {:net_basic, Nerves.InterimWiFi.NetBasic, :ifchanged, status})

        state
          |> goto_context(:down)
      {:error, _} ->
        # The interface isn't quite up yet. Retry
        Process.send_after self, :retry_ifadded, 250
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
    {:ok, status} = NetBasic.status(Nerves.InterimWiFi.NetBasic, state.ifname)
    GenEvent.notify(Nerves.InterimWiFi.EventManager, {:net_basic, Nerves.InterimWiFi.NetBasic, :ifchanged, status})

    state
      |> goto_context(:down)
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
  defp consume(:down, :ifremoved, state) do
    state
      |> stop_udhcpc
      |> stop_wpa
      |> goto_context(:removed)
  end

  ## Context: :associate_wifi
  defp consume(:associate_wifi, :ifup, state), do: state
  defp consume(:associate_wifi, :ifdown, state) do
    state
      |> stop_wpa
      |> goto_context(:down)
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
  defp consume(:dhcp, {:leasefail, _info}, state), do: state
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


  defp stop_wpa(state) do
    if is_pid(state.wpa_pid) do
      Nerves.WpaSupplicant.stop(state.wpa_pid)
      %Nerves.InterimWiFi.WiFiManager{state | wpa_pid: nil}
    else
      state
    end
  end
  defp start_wpa(state) do
    state = stop_wpa(state)
    wpa_control_pipe = @wpa_control_path <> "/#{state.ifname}"
    if !File.exists?(wpa_control_pipe) do
        # wpa_supplicant daemon not started, so launch it
        write_wpa_conf
        {_, 0} = System.cmd @wpa_supplicant_path,
                  ["-i#{state.ifname}",
                   "-c#{@wpa_config_file}",
                   "-C#{@wpa_control_path}",
                   "-Dnl80211,wext",
                   "-B"]

        # give it time to open the pipe
        :timer.sleep 250
    end

    {:ok, pid} = Nerves.WpaSupplicant.start_link(wpa_control_pipe,
                                          Nerves.InterimWiFi.EventManager)
    wpa_supplicant_settings = Map.new(state.settings)
    :ok = Nerves.WpaSupplicant.set_network(pid, wpa_supplicant_settings)
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
    :ok = NetBasic.setup(Nerves.InterimWiFi.NetBasic, state.ifname, info)
    :ok = Nerves.InterimWiFi.Resolvconf.setup(Nerves.InterimWiFi.Resolvconf, state.ifname, info)
    state
  end

  defp deconfigure(state) do
    :ok = Nerves.InterimWiFi.Resolvconf.clear(Nerves.InterimWiFi.Resolvconf, state.ifname)
    state
  end

  defp write_wpa_conf() do
    # Get the regulatory domain from the configuration.
    # "00" is the world domain
    regulatory_domain = Application.get_env(:nerves_interim_wifi, :regulatory_domain, "00")
    contents = "country=#{regulatory_domain}"
    File.write! @wpa_config_file, contents
  end
end
