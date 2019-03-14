defmodule Nerves.Network.Dhclientv4Conf do
  @moduledoc """
  A helper module for managing contents of the dhclient.conf(5) file i.e.:

  interface "eth0" {
    send host-name "audrey";
    send vendor-class-identifier "Mordor";
    send dhcp-client-identifier "Sauron";
    send user-class "One ring to rule them all and in the darkness bind them";
    request subnet-mask, broadcast-address, time-offset, routers, domain-name, domain-name-servers, host-name;
    require subnet-mask;
  }

  Any runtime change to the dhclient.conf(5) file requires dhclient to be restarted for the changes to become
  effective.
  """

  use GenServer
  require Logger
  require EEx

  alias Nerves.Network.Types

  @type dhclient_conf_t :: GenServer.server

  @ethernet_10MB "01"
  @eui64         "1b"


  @typedoc """
  The ifmap type is a map that can be an any subset of the fields listed below
  """
  @type ifmap :: %{
    host_name: String.t,
    vendor_class_identifier: String.t,
    client_identifier: String.t,
    user_class: String.t,
    request: list(String.t),
    require: list(String.t),
    fqdn: String.t,
    fqdn_server_update: String.t,
    fqdn_encoding: String.t,
    also_request: list(list(String.t))
  }
  | map()

  @type on_off_flip :: :on | :off
  @type server_update :: on_off_flip()
  @type fqdn_encoding :: on_off_flip()

  @typedoc """
  The dhcp_option type specifies the options that can be requested (nice to have ) and/or required by the DHCP client
  to accept the lease.
  """
  @type dhcp_option ::
    :"subnet-mask"
    | :"broadcast-address"
    | :"time-offset"
    | :"routers"
    | :"domain-name"
    | :"domain-search"
    | :"domain-name-servers"
    | :"host-name"
    | :"ntp-servers"
    | :"vendor-encapsulated-options"
    | :"dhcp-renewal-time"
    | :"dhcp-rebinding-time"
    | :"fqdn"
    | :"dhcp6.fqdn"

  @type protocol_timing_setting ::
    :timeout
    | :retry
    | :reboot
    | :select_timeout
    | :initial_interval

  @type protocol_timing ::
    %{
      optional(protocol_timing_setting()) => integer(),
    }

  @dhclient_conf_path "/etc/dhclientv4.conf"

  @server_name __MODULE__

  @doc """
  Default `dhclientv4.conf` path for this system.
  """
  @spec default_dhclient_conf_path :: Path.t
  def default_dhclient_conf_path do
    @dhclient_conf_path
  end

  # Returns a map containing default timing settings for a DHCP client
  # for further details please see the 'Protocol Timing Section' of https://www.isc.org/wp-content/uploads/2017/08/dhcp41clientconf.html .
  @spec
  defp timing_defaults() do
    %{
      :timeout => 33,
      :retry => 33,
      :reboot => 9,
      :select_timeout => 3,
      :initial_interval => 2
    }
  end

  @doc """
  Start the resolv.conf manager.
  """
  @spec start_link(Path.t, GenServer.options) :: GenServer.on_start
  def start_link(dhclient_conf_path \\ @dhclient_conf_path, opts \\ []) do
    GenServer.start_link(__MODULE__, dhclient_conf_path, opts)
  end

  @doc """
  Set the search domain for non fully qualified domain name lookups.
  """
  @spec set_vendor_class_id(Types.ifname, String.t) :: :ok
  def set_vendor_class_id(ifname, vendor_class_id) do
    GenServer.call(@server_name, {:set, :vendor_class_identifier, ifname, vendor_class_id})
  end

  @spec set_client_id(Types.ifname, String.t) :: :ok
  def set_client_id(ifname, client_id) do
    GenServer.call(@server_name, {:set, :client_identifier, ifname, client_id})
  end

  @spec set_user_class(Types.ifname, String.t() | nil) :: :ok
  @doc """
  RFC 3004             The User Class Option for DHCP        November 2000
  The format of this option is as follows:

         Code   Len   Value
        +-----+-----+---------------------  . . .  --+
        | 77  |  N  | User Class Data ('Len' octets) |
        +-----+-----+---------------------  . . .  --+

   where Value consists of one or more instances of User Class Data.
   Each instance of User Class Data is formatted as follows:






         UC_Len_i     User_Class_Data_i
        +--------+------------------------  . . .  --+
        |  L_i   | Opaque-Data ('UC_Len_i' octets)   |
        +--------+------------------------  . . .  --+

   Each User Class value (User_Class_Data_i) is indicated as an opaque
   field.  The value in UC_Len_i does not include the length field
   itself and MUST be non-zero.  Let m be the number of User Classes
   carried in the option.  The length of the option as specified in Len
   must be the sum of the lengths of each of the class names plus m:
   Len= UC_Len_1 + UC_Len_2 + ... + UC_Len_m + m.  If any instances of
   User Class Data are present, the minimum value of Len is two (Len =
   UC_Len_1 + 1 = 1 + 1 = 2).

   The Code for this option is 77.
  """
  def set_user_class(ifname, user_class = nil) do
    GenServer.call(@server_name, {:set, :user_class, ifname, user_class})
  end

  def set_user_class(ifname, user_class) do
    user_class_obj = to_string([String.length(user_class) | String.to_charlist(user_class)])
    GenServer.call(@server_name, {:set, :user_class, ifname, user_class_obj})
  end

  @spec set_fqdn(Types.ifname, String.t) :: :ok
  @doc """
  Function is meant for the DDNS support.
  Returns `:ok`.

  ## Parameters
  - ifname: Network interface name
  - fqdn: Fully qualified domain name as specified in https://tools.ietf.org/rfc/rfc1535.txt

  ## Examples

        iex> set_fqdn("eth0", "fully.qualified.domain.name.org.")
        :ok
  """
  def set_fqdn(ifname, fqdn) do
    GenServer.call(@server_name, {:set, :fqdn, ifname, fqdn})
  end

  @spec set_fqdn_server_update(Types.ifname, server_update()) :: :ok
  @doc """
  Function is meant for the DDNS support.
  Returns `:ok`.

  ## Parameters
  - ifname: Network interface name
  - fqdn_server_update: "on" | "off" string

  ## Examples

        iex> set_fqdn_server_update("eth0", :on)
        :ok

  """
  def set_fqdn_server_update(ifname, server_update = :on) do
    GenServer.call(@server_name, {:set, :fqdn_server_update, ifname, to_string(server_update)})
  end

  def set_fqdn_server_update(ifname, server_update = :off) do
    GenServer.call(@server_name, {:set, :fqdn_server_update, ifname, to_string(server_update)})
  end

  @spec set_fqdn_encoding(Types.ifname, fqdn_encoding()) :: :ok
  @doc """
  Function is meant for the DDNS support.
  Returns `:ok`.

  ## Parameters
  - ifname: Network interface name
  - fqdn_encoding: :on | :off

  ## Examples

        iex> set_fqdn_encoding("eth0", :on)
        :ok

  """
  def set_fqdn_encoding(ifname, encoding = :on) do
    GenServer.call(@server_name, {:set, :fqdn_encoding, ifname, to_string(encoding)})
  end

  def set_fqdn_encoding(ifname, encoding = :off) do
    GenServer.call(@server_name, {:set, :fqdn_encoding, ifname, to_string(encoding)})
  end

  @spec set_request_list(Types.ifname, list(String.t)) :: :ok
  def set_request_list(ifname, request_list) do
    GenServer.call(@server_name, {:set, :request, ifname, request_list})
  end

  @spec add_also_request(Types.ifname, list(String.t)) :: :ok
  def add_also_request(ifname, request_list) do
    GenServer.call(@server_name, {:add_to, :also_request, ifname, request_list})
  end

  @spec set_also_request(Types.ifname, list(list(String.t)) | [] | nil) :: :ok
  def set_also_request(ifname, request_list) do
    GenServer.call(@server_name, {:set, :also_request, ifname, request_list})
  end

  @spec set_require_list(Types.ifname, list(String.t)) :: :ok
  def set_require_list(ifname, require_list) do
    GenServer.call(@server_name, {:set, :require, ifname, require_list})
  end

  @spec set_timing(protocol_timing()) :: :ok
  def set_timing(timing) do
    GenServer.call(@server_name, {:set, :timing, timing})
  end

  @spec clear(Types.ifname) :: :ok
  def clear(ifname) do
    GenServer.call(@server_name, {:clear, ifname})
  end

  @spec set_protocol_timing(protocol_timing()) :: :ok
  @doc """
  Function is meant for setting the DHCP timing
  Returns `:ok`.

  ## Parameters
  - timing: A map containing set of timing settings see @type protocol_timing_setting

  ## Examples

        iex> set_protocol_timing(
        ...> %{
        ...>   :timeout => 33,
        ...>   :retry => 33,
        ...>   :reboot => 9,
        ...>   :"select-timeout" => 3,
        ...>   :"initial-interval" => 2
        ...> })
        :ok
  """
  def set_protocol_timing(timing) do
    GenServer.call(@server_name, {:set, :timing, timing})
  end

  ## GenServer

  @typedoc "State of the server."
  @type state :: %{ifname: Types.ifname, ifmap: ifmap, timing: protocol_timing()}

  @spec end_interface_text() :: String.t
  defp end_interface_text(), do: "}\n"

  @spec list_of_atoms_to_comma_separated_strings(list(dhcp_option), String.t, String.t) :: String.t
  defp list_of_atoms_to_comma_separated_strings(list, prefix, termination) do
    items_string =
      for item <- list do
        to_string(item)
      end
      |> Enum.join(", ")

    "  " <> prefix <> " " <> items_string <> termination
  end

  @spec config_list_entry_text(atom(), ifmap) :: String.t
  defp config_list_entry_text(item_name, ifmap) when is_atom(item_name) and item_name in [:request, :require] do
    case ifmap[item_name] do
      [] -> ""
      nil -> ""
      list -> list_of_atoms_to_comma_separated_strings(list, to_string(item_name), ";\n")
    end
  end

  @spec request_text(ifmap) :: String.t
  defp request_text(ifmap) do
    #request subnet-mask, broadcast-address, time-offset, routers, domain-name, domain-name-servers, host-name;
    config_list_entry_text(:request, ifmap)
  end

  defp also_request_entry([]), do: ""
  defp also_request_entry(item) when is_list(item) do
    list_of_atoms_to_comma_separated_strings(item, "also request", ";\n")
  end

  defp also_request_text(nil), do: ""
  defp also_request_text([]), do: ""
  defp also_request_text(list) when is_list(list) do
    for item <- list do
      also_request_entry(item)
    end
    |> Enum.join("")
  end

  @spec also_request_text(ifmap) :: String.t
  defp also_request_text(ifmap) do
    also_request_text(ifmap[:also_request])
  end

  @spec require_text(ifmap) :: String.t
  defp require_text(ifmap) do
    #require subnet-mask;
    config_list_entry_text(:require, ifmap)
  end

  @spec dhclient_timing_config_template(protocol_timing()) :: String.t()
  defp dhclient_timing_config_template(timing) do
    ~s"""
    <%= if @timeout do %>timeout <%= @timeout%>;\n<% end %>\
    <%= if @retry do %>retry <%= @retry%>;\n<% end %>\
    <%= if @reboot do %>reboot <%= @reboot%>;\n<% end %>\
    <%= if @select_timeout do %>select-timeout <%= @select_timeout%>;\n<% end %>\
    <%= if @initial_interval do %>initial-interval <%= @initial_interval%>;\n<% end %>
    """
  end

  defp dhclient_iface_config_template(_ifname, ifmap) do
    ~s"""
    interface "<%= @interface %>" {\n\
    <%= if @host_name do %>  send host-name "<%= @host_name %>";\n<% end %>\
    <%= if @vendor_class_identifier do %>  send vendor-class-identifier "<%= @vendor_class_identifier %>";\n<% end %>\
    <%= if @hardware_type do %>\
    <%= if @client_identifier do %>  send dhcp-client-identifier <%= @client_identifier %>;\n<% end %>\
    <% else %>\
    <%= if @client_identifier do %>  send dhcp-client-identifier "<%= @client_identifier %>";\n<% end %>\
    <% end %>\
    <%= if @user_class do %>  send user-class "<%= @user_class %>";\n<% end %>\
    <%= if @fqdn do %>  send fqdn.fqdn "<%= @fqdn %>";\n\
    <%= if @fqdn_encoding do %>  send fqdn.encoded <%= @fqdn_encoding %>;\n<% end %>\
    <%= if @fqdn_server_update do %>  send fqdn.server-update <%= @fqdn_server_update %>;\n<% end %>\
    <% end %>\
    """
    <> request_text(ifmap)
    <> also_request_text(ifmap)
    <> require_text(ifmap)
    <> end_interface_text()
  end

  # This is a placeholder for eventual future custom DHCP options definitions
  @spec outermost_options_definitions(state) :: String.t()
  defp outermost_options_definitions(state) do
    dhclient_timing_config_template(state[:timing])
    |> EEx.eval_string(
        assigns: [
            timeout: nil,
            retry: nil,
            reboot: nil,
            select_timeout: nil,
            initial_interval: nil,
        ]
        |> Keyword.merge( Map.to_list(state[:timing]) )
    )
        #"""
        #    timeout 33;
        #    retry 33;
        #    reboot 9;
        #    select-timeout 3;
        #    initial-interval 2;\n
        #    """
  end

  @spec construct_contents({Types.ifname, ifmap} | any) :: String.t
  defp construct_contents({ifname, ifmap}) do
    Logger.debug("construct_contents[#{ifname}]: ifmap = #{inspect ifmap}")

    dhclient_iface_config_template(ifname, ifmap)
    |> EEx.eval_string(
        assigns: [
            interface: ifname,
            vendor_class_identifier: nil,
            client_identifier: nil,
            user_class: nil,
            host_name: nil,
            hardware_type: false,
            fqdn: nil,
            fqdn_server_update: nil,
        ]
        |> Keyword.merge( Map.to_list(ifmap) )
        |> Keyword.merge(interface: ifname) )
  end

  defp file_write(filename, []) do
    File.write!(filename, [""])
  end

  defp file_write(filename, list) do
    File.write!(filename, list)
  end

  @spec write_dhclient_conf(%{filename: Path.t, ifmap: ifmap | map}) :: :ok
  defp write_dhclient_conf(state) do
    Logger.debug fn -> "#{__MODULE__}: write_dhclient_conf state = #{inspect state}" end

    contents =
      [
        outermost_options_definitions(state)
        | Enum.map(state.ifmap, &construct_contents/1)
      ]

    Logger.debug("+++++++ Contents +++++++")
    Logger.debug("#{inspect contents}")
    Logger.debug("++++++++++++++++++++++++")

    file_write(state.filename, contents)
  end

  @spec update_item(atom(), Types.ifname, String.t(), state) :: state
  defp update_item(item_name, ifname, value, state)  do
    new_ifentry = state.ifmap
                    |> Map.get(ifname, %{})
                    |> Map.merge(%{item_name => value})

    %{state | ifmap: Map.put(state.ifmap, ifname, new_ifentry)}
  end

  @spec prefix_client_id(String.t()) :: String.t()
  defp prefix_client_id(value) do
    cond do
      Nerves.Network.Utils.is_mac_eui_48?(value) -> @ethernet_10MB <> ":" <> value
      Nerves.Network.Utils.is_mac_eui_64?(value) -> @eui64 <> ":" <> value
      true -> value
    end
  end
  @spec update_state(atom(), Types.ifname, String.t() | nil, state) :: state
  #For client_identifier we shall specify if this is a harware type (MAC address: EUI 48 or 64)
  #Full list of types is here: https://www.iana.org/assignments/arp-parameters/arp-parameters.xhtml
  #Or as defined in https://tools.ietf.org/html/rfc5342

  defp update_state(item_name = :client_identifier, ifname, value = nil, state)  do
    update_item(item_name, ifname, value, state)
  end

  @spec update_state(atom(), protocol_timing() | nil, state) :: state
  defp update_state(item_name = :timing, value = nil, state)  do
    %{state | timing: %{}}
  end

  defp update_state(item_name = :timing, value, state)  do
    %{state | timing: value}
  end

  defp update_state(item_name = :client_identifier, ifname, value, state)  do
    hardware_type = Nerves.Network.Utils.is_mac_eui_48?(value) or Nerves.Network.Utils.is_mac_eui_64?(value)

    new_state = update_item(item_name, ifname, prefix_client_id(value), state)

    new_ifentry = new_state.ifmap
                    |> Map.get(ifname, %{})
                    |> Map.merge(%{:hardware_type => hardware_type})

    %{new_state | ifmap: Map.put(state.ifmap, ifname, new_ifentry)}
  end

  defp update_state(item_name, ifname, value, state)  do
    update_item(item_name, ifname, value, state)
  end

  @spec add_to_also_request(Type.ifname, list(list(String.t)) | [] | nil, state) :: state
  defp add_to_also_request(_ifname, nil, state), do: state
  defp add_to_also_request(_ifname, [], state), do: state
  defp add_to_also_request(ifname, value, state) when is_list(value) do
    ifmap = Map.get(state.ifmap, ifname, %{})
    old_also_request = Map.get(ifmap, :"also_request", [])
    new_ifmap = Map.merge(ifmap, %{:also_request => [ value | old_also_request ]})
    %{state | ifmap: Map.put(state.ifmap, ifname, new_ifmap)}
  end

  def handle_call({:set, item_name, ifname, value}, _from, state) when is_atom(item_name) and
    item_name in [
      :host_name,
      :vendor_class_identifier,
      :client_identifier,
      :user_class,
      :request,
      :require,
      :fqdn,
      :fqdn_server_update,
      :fqdn_encoding,
      :also_request
    ] do
    Logger.debug("handle_call item_name = #{inspect item_name} ifname = #{ifname}; value = #{inspect value} state = #{inspect state}")

    state = update_state(item_name, ifname, value, state)

    write_dhclient_conf(state)
    {:reply, :ok, state}
  end

  def handle_call({:set, item_name = :timing, value}, _from, state) do
    Logger.debug("handle_call item_name = #{inspect item_name}; value = #{inspect value} state = #{inspect state}")

    state = update_state(item_name, value, state)

    write_dhclient_conf(state)
    {:reply, :ok, state}
  end

  def handle_call({:add_to, :also_request, ifname, value}, _from, state) do
    Logger.debug("handle_call :add_to :also_request ifname = #{ifname}; value = #{inspect value} state = #{inspect state}")

    state = add_to_also_request(ifname, value, state)

    write_dhclient_conf(state)
    {:reply, :ok, state}
  end

  def handle_call({:clear, ifname}, _from, state) do
    Logger.debug("#{__MODULE__}: :clear state = #{inspect state}")

    new_state = %{state | ifmap: Map.put(state.ifmap, ifname, %{})}

    write_dhclient_conf(new_state)
    {:reply, :ok, new_state}
  end

  @doc false
  def init(filename) do
    state = %{filename: filename, ifmap: %{}, timing: timing_defaults()}
    write_dhclient_conf(state)
    Logger.debug("#{__MODULE__}: filename = #{inspect filename}: state = #{inspect state}")
    {:ok, state}
  end

end
