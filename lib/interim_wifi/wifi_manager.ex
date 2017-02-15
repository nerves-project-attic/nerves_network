defmodule Nerves.InterimWiFi.WiFiManager do
  use GenServer
  require Logger
  alias Nerves.InterimWiFi.Utils

  @moduledoc false

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

  # defmodule EventHandler do
  #   use GenEvent
  #
  #   @moduledoc false
  #
  #   def init({manager, ifname}) do
  #     {:ok, %{manager: manager, ifname: ifname}}
  #   end
  #
  #
  # end

  def init({ifname, settings}) do
    # Make sure that the interface is enabled or nothing will work.
    Logger.info "WiFiManager(#{ifname}) starting"
    Logger.info "Register Nerves.NetworkInterface #{inspect ifname}"
    # Register for nerves_network_interface events
    {:ok, _} = Registry.register(Nerves.NetworkInterface, ifname, [])
    |> IO.inspect

    Logger.info "Done Registering"
    state = %Nerves.InterimWiFi.WiFiManager{settings: settings, ifname: ifname}

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

  def handle_event({Nerves.NetworkInterface, :ifadded, %{:ifname => ifname}}) do
    Logger.info "WiFiManager.EventHandler(#{ifname}) ifadded"
    :ifadded
  end
  # :ifmoved occurs on systems that assign stable names to removable
  # interfaces. I.e. the interface is added under the dynamically chosen
  # name and then quickly renamed to something that is stable across boots.
  def handle_event({Nerves.NetworkInterface, :ifmoved, %{:ifname => ifname}}) do
    Logger.info "WiFiManager.EventHandler(#{ifname}) ifadded (moved)"
    :ifadded
  end
  def handle_event({Nerves.NetworkInterface, :ifremoved, %{:ifname => ifname}}) do
    Logger.info "WiFiManager.EventHandler(#{ifname}) ifremoved"
    :ifremoved
  end

  # Filter out ifup and ifdown events
  # :is_up reports whether the interface is enabled or disabled (like by the wifi kill switch)
  # :is_lower_up reports whether the interface has associated with an AP
  def handle_event({Nerves.NetworkInterface, :ifchanged, %{ifname: ifname, is_up: true}}) do
    Logger.info "WiFiManager.EventHandler(#{ifname}) ifup"
    :ifup
  end
  def handle_event({Nerves.NetworkInterface, :ifchanged, %{ifname: ifname, is_up: false}}) do
    Logger.info "WiFiManager.EventHandler(#{ifname}) ifdown"
    :ifdown
  end

  # wpa_supplicant events
  def handle_event({Nerves.WpaSupplicant, :"CTRL-EVENT-CONNECTED", %{ifname: ifname}}) do
    Logger.info "WiFiManager.EventHandler(#{ifname}) wifi_connected"
    :wifi_connected
  end
  def handle_event({Nerves.WpaSupplicant, :"CTRL-EVENT-DISCONNECTED", %{ifname: ifname}}) do
    Logger.info "WiFiManager.EventHandler(#{ifname}) wifi_disconnected"
    :wifi_disconnected
  end

  # Ignore events
  def handle_event({Nerves.WpaSupplicant, event, %{ifname: ifname}}) do
    Logger.info "WiFiManager.EventHandler(#{ifname}): ignoring event: #{inspect event}"
    :noop
  end
  def handle_event({Nerves.NetworkInterface, event, %{ifname: ifname}}) do
    Logger.info "WiFiManager.EventHandler(#{ifname}): ignoring event: #{inspect event}"
    :noop
  end

  # # DHCP events
  # # :bound, :renew, :deconfig, :nak
  def handle_info({Nerves.Udhcpc, event, info}, %{ifname: ifname} = s) do
    Logger.info "DHCPManager.EventHandler(#{ifname}) udhcpc #{inspect event}"
    s = consume(s.context, {event, info}, s)
    {:noreply, s}
  end

  def handle_info({registry, _, _} = event, %{ifname: ifname} = s)
   when registry in [Nerves.NetworkInterface, Nerves.WpaSupplicant] do
    event = handle_event(event)
    Logger.info "WiFiManager(#{ifname}, #{s.context}) got event #{inspect event}"
    s = consume(s.context, event, s)
    {:noreply, s}
  end

  def handle_info(event, s) do
    Logger.info "WiFiManager.EventHandler(#{s.ifname}): ignoring event: #{inspect event}"
    {:noreply, s}
  end

  ## State machine implementation
  defp goto_context(state, newcontext) do
    %Nerves.InterimWiFi.WiFiManager{state | context: newcontext}
  end

  defp consume(_, :noop, state), do: state
  ## Context: :removed
  defp consume(:removed, :ifadded, state) do
    case Nerves.NetworkInterface.ifup(state.ifname) do
      :ok ->

        {:ok, status} = Nerves.NetworkInterface.status state.ifname
        Utils.notify(Nerves.NetworkInterface, state.ifname, :ifchanged, status)

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
    Utils.notify(Nerves.NetworkInterface, state.ifname, :ifchanged, status)

    state
      |> goto_context(:down)
  end

  ## Context: :down
  defp consume(:down, :ifadded, state), do: state
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
        write_wpa_conf()
        {_, 0} = System.cmd @wpa_supplicant_path,
                  ["-i#{state.ifname}",
                   "-c#{@wpa_config_file}",
                   "-C#{@wpa_control_path}",
                   "-Dnl80211,wext",
                   "-B"]

        # give it time to open the pipe
        :timer.sleep 250
    end

    {:ok, pid} = Nerves.WpaSupplicant.start_link(state.ifname, wpa_control_pipe, name: :"Nerves.WpaSupplicant.#{state.ifname}")
    Logger.info "Register Nerves.WpaSupplicant #{inspect state.ifname}"
    {:ok, _} = Registry.register(Nerves.WpaSupplicant, state.ifname, [])
    |> IO.inspect
    wpa_supplicant_settings = Map.new(state.settings)
    case Nerves.WpaSupplicant.set_network(pid, wpa_supplicant_settings) do
      :ok -> :ok
      error ->
        Logger.info "WiFiManager(#{state.ifname}, #{state.context}) wpa_supplicant set_network error: #{inspect error}"
        # TODO: Send event here
    end

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
    Logger.info "Register Nerves.Udhcpc #{inspect state.ifname}"
    {:ok, _} = Registry.register(Nerves.Udhcpc, state.ifname, [])
    %Nerves.InterimWiFi.WiFiManager{state | dhcp_pid: pid}
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

  defp write_wpa_conf() do
    # Get the regulatory domain from the configuration.
    # "00" is the world domain
    regulatory_domain = Application.get_env(:nerves_interim_wifi, :regulatory_domain, "00")
    contents = "country=#{regulatory_domain}"
    File.write! @wpa_config_file, contents
  end
end
