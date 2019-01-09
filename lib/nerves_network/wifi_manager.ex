defmodule Nerves.Network.WiFiManager do
  use GenServer
  require Logger
  import Nerves.Network.Utils
  alias Nerves.Network.Types

  @moduledoc false

  # The following are Nerves locations of the supplicant. If not using
  # Nerves, these may be different.
  @wpa_supplicant_path "/usr/sbin/wpa_supplicant"
  @wpa_control_path "/var/run/wpa_supplicant"
  @wpa_config_file "/tmp/nerves_network_wpa.conf"

  defstruct context: :removed,
            # State machine
            # Interface
            ifname: nil,
            # Passed in via setup/2
            settings: nil,
            # map of wpa_supplicant network id to network_interface settings
            ip_settings: nil,
            # map of wpa_supplicant network id to wpa_supplicant network
            wpa_settings: nil,
            # DHCP client pid
            dhcp_pid: nil,
            # DHCP server pid
            dhcpd_pid: nil,
            # wpa_supplicant pid
            wpa_pid: nil,
            # Current wpa_supplicant id
            current_id: nil

  @typep context :: Types.interface_context() | :associate_wifi | :dhcp

  @typedoc "State of the GenServer."
  @type t :: %__MODULE__{
          context: context,
          ifname: Types.ifname() | nil,
          ip_settings: %{optional(integer()) => Types.ip_settings()},
          wpa_settings: %{optional(integer()) => map},
          dhcp_pid: GenServer.server() | nil,
          dhcpd_pid: GenServer.server() | nil,
          wpa_pid: GenServer.server() | nil
        }

  @doc false
  @spec start_link(Types.ifname(), Nerves.Network.setup_settings(), GenServer.options()) ::
          GenServer.on_start()
  def start_link(ifname, settings, opts \\ []) do
    GenServer.start_link(__MODULE__, {ifname, settings}, opts)
  end

  def init({ifname, settings}) when is_list(settings) do
    # Make sure that the interface is enabled or nothing will work.
    Logger.info("WiFiManager(#{ifname}) starting")
    Logger.info("WiFiManager(#{ifname}) Register Nerves.NetworkInterface")
    # Register for nerves_network_interface events and udhcpc events
    {:ok, _} = Registry.register(Nerves.NetworkInterface, ifname, [])

    # Register for nerves_network_interface events and udhcpc events
    {:ok, _} = Registry.register(Nerves.Udhcpc, ifname, [])

    settings =
      settings
      |> Map.new()
      # Drop ip settings.
      # This is a backward incompatible change for anything
      # other than DHCP (default)
      |> Map.drop([
        :ipv4_address_method,
        :ipv4_address,
        :ipv4_broadcast,
        :ipv4_subnet_mask,
        :ipv4_gateway,
        :domain,
        :nameservers
      ])

    state = %__MODULE__{ifname: ifname, settings: settings}

    Logger.info("WiFiManager(#{ifname}) Done Registering")

    # If the interface currently exists send ourselves a message that it
    # was added to get things going.
    current_interfaces = Nerves.NetworkInterface.interfaces()

    state =
      if Enum.member?(current_interfaces, ifname) do
        consume(state.context, :ifadded, state)
      else
        state
      end

    {:ok, state}
  end

  @typedoc "Event parsed from SystemRegistry WpaSupplicant messages."
  @type wifi_event :: :wifi_connected | :wifi_disconnected | :noop

  @typedoc "Event from SystemRegistry Udhcpc messages."
  @type udhcp_event ::
          {:bound, Types.udhcp_info()}
          | {:deconfig, Types.udhcp_info()}
          | {:nak, Types.udhcp_info()}
          | {:renew, Types.udhcp_info()}

  @typedoc "Event from SystemRegistry."
  @type registry_event_tuple ::
          {Nerves.NetworkInterface, atom, %{ifname: Types.ifname()}}
          | {Nerves.WpaSupplicant, atom, %{ifname: Types.ifname(), is_up: boolean}}
          | {Nerves.Udhcpc, atom, %{ifname: Types.ifname()}}

  @typedoc "Event from either NetworkInterface or WpaSupplicant."
  @type registry_event :: Types.ifevent() | wifi_event | udhcp_event

  @spec handle_registry_event(registry_event_tuple) :: registry_event
  defp handle_registry_event({Nerves.NetworkInterface, :ifadded, %{:ifname => ifname}}) do
    Logger.info("WiFiManager(#{ifname}) network_interface ifadded")
    :ifadded
  end

  # :ifmoved occurs on systems that assign stable names to removable
  # interfaces. I.e. the interface is added under the dynamically chosen
  # name and then quickly renamed to something that is stable across boots.
  defp handle_registry_event({Nerves.NetworkInterface, :ifmoved, %{:ifname => ifname}}) do
    Logger.info("WiFiManager(#{ifname}) network_interface ifadded (moved)")
    :ifadded
  end

  defp handle_registry_event({Nerves.NetworkInterface, :ifremoved, %{:ifname => ifname}}) do
    Logger.info("WiFiManager(#{ifname}) network_interface ifremoved")
    :ifremoved
  end

  # Filter out ifup and ifdown events
  # :is_up reports whether the interface is enabled or disabled (like by the wifi kill switch)
  # :is_lower_up reports whether the interface has associated with an AP
  defp handle_registry_event(
         {Nerves.NetworkInterface, :ifchanged, %{ifname: ifname, is_up: true}}
       ) do
    Logger.info("WiFiManager(#{ifname}) network_interface ifup")
    :ifup
  end

  defp handle_registry_event(
         {Nerves.NetworkInterface, :ifchanged, %{ifname: ifname, is_up: false}}
       ) do
    Logger.info("WiFiManager(#{ifname}) network_interface ifdown")
    :ifdown
  end

  # Ignore events
  defp handle_registry_event({Nerves.NetworkInterface, event, %{ifname: ifname}}) do
    Logger.info("WiFiManager(#{ifname}): ignoring event: #{inspect(event)}")
    :noop
  end

  # wpa_supplicant events
  defp handle_registry_event(
         {Nerves.WpaSupplicant, {:"CTRL-EVENT-CONNECTED", _bssid, :completed, %{id: id} = _info},
          %{ifname: ifname}}
       ) do
    Logger.info("WiFiManager(#{ifname}) wpa_supplicant wifi_connected")
    {:wifi_connected, id}
  end

  defp handle_registry_event(
         {Nerves.WpaSupplicant, {:"CTRL-EVENT-DISCONNECTED", _bssid, _info}, %{ifname: ifname}}
       ) do
    Logger.info("WiFiManager(#{ifname}) wpa_supplicant wifi_disconnected")
    :wifi_disconnected
  end

  defp handle_registry_event(
         {Nerves.WpaSupplicant, :"CTRL-EVENT-NETWORK-NOT-FOUND", %{ifname: ifname}}
       ) do
    Logger.info("WiFiManager(#{ifname}) wpa_supplicant network_not_found")
    :wifi_disconnected
  end

  # Ignore events
  defp handle_registry_event({Nerves.WpaSupplicant, event, %{ifname: ifname}}) do
    Logger.info("WiFiManager(#{ifname}): ignoring event: #{inspect(event)}")
    :noop
  end

  defp handle_registry_event({Nerves.Udhcpc, :bound, %{ifname: ifname} = info}) do
    Logger.info("WiFiManager(#{ifname}): udhcp bound")
    {:bound, info}
  end

  defp handle_registry_event({Nerves.Udhcpc, :deconfig, %{ifname: ifname} = info}) do
    Logger.info("WiFiManager(#{ifname}): udhcp deconfig")
    {:deconfig, info}
  end

  defp handle_registry_event({Nerves.Udhcpc, :nak, %{ifname: ifname} = info}) do
    Logger.info("WiFiManager(#{ifname}): udhcp nak")
    {:nak, info}
  end

  defp handle_registry_event({Nerves.Udhcpc, :renew, %{ifname: ifname} = info}) do
    Logger.info("WiFiManager(#{ifname}): udhcp renew")
    {:renew, info}
  end

  defp handle_registry_event({Nerves.Udhcpc, event, %{ifname: ifname}}) do
    Logger.info("WiFiManager(#{ifname}): ignoring event: #{inspect(event)}")
    :noop
  end

  # This happens when we are managing a wireless interface, but we haven't got
  # the `ifup` event yet.
  def handle_call(_call, _from, %{wpa_pid: nil} = s) do
    {:reply, {:error, :wpa_not_started}, s}
  end

  # if the wpa_pid is nil, we don't want to actually create the call.
  def handle_call(:scan, _from, %{wpa_pid: wpa_pid} = s) when is_pid(wpa_pid) do
    results = Nerves.WpaSupplicant.scan(wpa_pid)
    {:reply, results, s}
  end

  def handle_call(:status, _from, %{wpa_pid: wpa_pid} = s) when is_pid(wpa_pid) do
    results = Nerves.WpaSupplicant.status(wpa_pid)
    {:reply, results, s}
  end

  # # DHCP events
  # # :bound, :renew, :deconfig, :nak
  def handle_info({Nerves.Udhcpc, _, info} = event, %{ifname: ifname} = s) do
    Logger.info("WiFiManager(#{ifname}) udhcpc #{inspect(event)}")
    scope(ifname) |> SystemRegistry.update(info)
    event = handle_registry_event(event)
    s = consume(s.context, event, s)
    {:noreply, s}
  end

  def handle_info({registry, _, ifstate} = event, %{ifname: ifname} = s)
      when registry in [Nerves.NetworkInterface, Nerves.WpaSupplicant] do
    event = handle_registry_event(event)
    scope(ifname) |> SystemRegistry.update(ifstate)

    Logger.info(
      "#{inspect(registry)} - WiFiManager(#{ifname}, #{s.context}) got event #{inspect(event)}"
    )

    s = consume(s.context, event, s)
    {:noreply, s}
  end

  def handle_info(event, s) do
    Logger.info("WiFiManager(#{s.ifname}): ignoring event: #{inspect(event)}")
    {:noreply, s}
  end

  def terminate(reason, s) do
    Logger.info("WiFiManager(#{s.ifname}): terminate(#{inspect(reason)})")

    s
    |> stop_dhcp()
    |> stop_wpa()
  end

  @spec goto_context(t, context) :: t
  ## State machine implementation
  defp goto_context(state, newcontext) do
    %Nerves.Network.WiFiManager{state | context: newcontext}
  end

  @spec consume(context, registry_event, t) :: t
  defp consume(_, :noop, state), do: state

  ## Context: :removed
  defp consume(:removed, :ifadded, state) do
    :ok = Nerves.NetworkInterface.ifup(state.ifname)
    {:ok, status} = Nerves.NetworkInterface.status(state.ifname)
    notify(Nerves.NetworkInterface, state.ifname, :ifchanged, status)
    goto_context(state, :down)
  end

  defp consume(:removed, :ifdown, state), do: state

  ## Context: :down
  defp consume(:down, :ifadded, state), do: state

  defp consume(:down, :ifup, state) do
    state
    |> start_wpa
    |> goto_context(:associate_wifi)
  end

  defp consume(:down, :ifdown, state) do
    state
    |> stop_dhcp
    |> stop_wpa
  end

  defp consume(:down, :ifremoved, state) do
    state
    |> stop_dhcp
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

  defp consume(:associate_wifi, {:wifi_connected, id}, state) do
    state
    |> Map.put(:current_id, id)
    |> setup_ip_settings
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
    |> stop_dhcp
    |> goto_context(:down)
  end

  defp consume(:dhcp, :wifi_disconnected, state) do
    state
    |> stop_dhcp
    |> goto_context(:associate_wifi)
  end

  defp consume(:dhcp, _probably_not_important, state), do: state

  ## Context: :up

  defp consume(:up, :ifup, state), do: state

  # already configured.
  defp consume(:up, {:bound, _info}, state), do: state

  # already configured.
  defp consume(:up, {:renew, _info}, state), do: state

  defp consume(:up, :ifdown, state) do
    state
    |> stop_dhcp
    |> deconfigure
    |> goto_context(:down)
  end

  defp consume(:up, :wifi_disconnected, state) do
    if is_pid(state.wpa_pid) do
      Nerves.WpaSupplicant.reassociate(state.wpa_pid)
    end

    state
    |> stop_dhcp
    |> goto_context(:associate_wifi)
  end

  defp consume(:up, {:wifi_connected, id}, state) do
    state
    |> Map.put(:current_id, id)
    |> stop_dhcp
    |> setup_ip_settings
    |> goto_context(:dhcp)
  end

  @spec stop_wpa(t) :: t
  defp stop_wpa(state) do
    if is_pid(state.wpa_pid) do
      Nerves.WpaSupplicant.stop(state.wpa_pid)
      %Nerves.Network.WiFiManager{state | wpa_pid: nil}
    else
      state
    end
  end

  @spec start_wpa(t) :: t
  defp start_wpa(state) do
    state = stop_wpa(state)
    wpa_control_pipe = @wpa_control_path <> "/#{state.ifname}"

    if !File.exists?(wpa_control_pipe) do
      # wpa_supplicant daemon not started, so launch it
      write_wpa_conf()

      {_, 0} =
        System.cmd(@wpa_supplicant_path, [
          "-i#{state.ifname}",
          "-c#{@wpa_config_file}",
          "-C#{@wpa_control_path}",
          "-Dnl80211,wext",
          "-B"
        ])

      # give it time to open the pipe
      :timer.sleep(250)
    end

    {:ok, pid} =
      Nerves.WpaSupplicant.start_link(
        state.ifname,
        wpa_control_pipe,
        name: :"Nerves.WpaSupplicant.#{state.ifname}"
      )

    Logger.info("Register Nerves.WpaSupplicant #{inspect(state.ifname)}")
    {:ok, _} = Registry.register(Nerves.WpaSupplicant, state.ifname, [])

    _ = Nerves.WpaSupplicant.remove_all_networks(pid)

    {ip_settings, wpa_settings} =
      Enum.reduce(parse_settings(state.settings), {%{}, %{}}, fn {ip_settings, wpa_settings},
                                                                 {ip_acc, wpa_acc} ->
        case Nerves.WpaSupplicant.add_network(pid, wpa_settings) do
          {:ok, id} ->
            {Map.put(ip_acc, id, ip_settings), Map.put(wpa_acc, id, wpa_settings)}

          error ->
            Logger.error(
              "WiFiManager(#{state.ifname}, wpa_supplicant add_network error: #{inspect(error)}"
            )

            notify(Nerves.WpaSupplicant, state.ifname, error, %{ifname: state.ifname})
            {ip_acc, wpa_acc}
        end
      end)

    _ = Nerves.WpaSupplicant.reassociate(pid)

    %Nerves.Network.WiFiManager{
      state
      | wpa_pid: pid,
        wpa_settings: wpa_settings,
        ip_settings: ip_settings
    }
  end

  # This allows supplying a list of networks
  defp parse_settings(%{networks: networks}) when is_list(networks) do
    networks
    |> Enum.map(&parse_network/1)
  end

  # This is the original API for supplying a single
  # network.
  # Example %{ssid: "hello", psk: "secret", key_mgmt: :"WPA-PSK"}
  defp parse_settings(%{} = settings), do: parse_settings(%{networks: [settings]})

  # If network is passed in as a list, convert it to a map.
  # Example: [ssid: "hello", psk: "secret", key_mgmt: :"WPA-PSK"]
  defp parse_network(network) when is_list(network) do
    network
    |> Map.new()
    |> parse_network()
  end

  # Convert `key_mgmt` to an atom if supplied as binary.
  # TODO(Connor) - This should be done for :wep_key0..3 and :wep_tx_keyidx
  defp parse_network(settings = %{key_mgmt: key_mgmt}) when is_binary(key_mgmt) do
    %{settings | key_mgmt: String.to_atom(key_mgmt)}
    |> parse_settings
  end

  # Detect when the user specifies no WiFi security but supplies a
  # key anyway. This confuses wpa_supplicant and causes the failure
  # described in #39.
  defp parse_network(settings = %{key_mgmt: :NONE, psk: _psk}) do
    Map.delete(settings, :psk)
    |> parse_settings
  end

  defp parse_network(%{} = settings) do
    {_ip_settings, _wpa_settings} =
      Map.split(settings, [
        :ipv4_address_method,
        :ipv4_address,
        :ipv4_broadcast,
        :ipv4_subnet_mask,
        :ipv4_gateway,
        :domain,
        :nameservers
      ])
  end

  @spec stop_dhcp(t) :: t
  defp stop_dhcp(state) do
    state =
      if is_pid(state.dhcp_pid) do
        Nerves.Network.Udhcpc.stop(state.dhcp_pid)
        %Nerves.Network.WiFiManager{state | dhcp_pid: nil}
      else
        state
      end

    state =
      if is_pid(state.dhcpd_pid) do
        _ = OneDHCPD.stop_server(state.ifname)
        %Nerves.Network.WiFiManager{state | dhcpd_pid: nil}
      else
        state
      end

    deconfigure(state)
  end

  @spec setup_ip_settings(t) :: t
  defp setup_ip_settings(state) do
    state = stop_dhcp(state)

    case state.ip_settings[state.current_id] do
      %{ipv4_address_method: :dhcpd} = info ->
        ipv4_address =
          OneDHCPD.default_ip_address(state.ifname)
          |> :inet.ntoa()
          |> to_string()

        ipv4_subnet_mask =
          OneDHCPD.default_subnet_mask()
          |> :inet.ntoa()
          |> to_string()

        new_info =
          Map.merge(info, %{
            ipv4_address_method: :static,
            ipv4_address: ipv4_address,
            ipv4_subnet_mask: ipv4_subnet_mask
          })

        {:ok, pid} = OneDHCPD.start_server(state.ifname)
        state = %Nerves.Network.WiFiManager{state | dhcpd_pid: pid}
        configure(state, new_info)

      %{ipv4_address_method: :static} = info ->
        configure(state, info)

      _ ->
        {:ok, pid} = Nerves.Network.Udhcpc.start_link(state.ifname)
        %Nerves.Network.WiFiManager{state | dhcp_pid: pid}
    end
  end

  @spec configure(t, Types.udhcp_info()) :: t
  defp configure(state, info) do
    :ok = Nerves.NetworkInterface.setup(state.ifname, info)
    :ok = Nerves.Network.Resolvconf.setup(Nerves.Network.Resolvconf, state.ifname, info)
    state
  end

  @spec deconfigure(t) :: t
  defp deconfigure(state) do
    clear = [
      ipv4_address: "0.0.0.0",
      domain: nil,
      nameservers: []
    ]

    :ok = Nerves.NetworkInterface.setup(state.ifname, clear)
    :ok = Nerves.Network.Resolvconf.clear(Nerves.Network.Resolvconf, state.ifname)
    state
  end

  @spec write_wpa_conf :: :ok | no_return
  defp write_wpa_conf do
    # Get the regulatory domain from the configuration.
    # "00" is the world domain
    regulatory_domain = Application.get_env(:nerves_network, :regulatory_domain, "00")
    contents = "country=#{regulatory_domain}"
    File.write!(@wpa_config_file, contents)
  end
end
