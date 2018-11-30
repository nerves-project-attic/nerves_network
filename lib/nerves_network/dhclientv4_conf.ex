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
  """

  use GenServer
  require Logger
  require EEx

  alias Nerves.Network.Types

  @type dhclient_conf_t :: GenServer.server

  @type ifmap :: %{
    host_name: String.t,
    vendor_class_identifier: String.t,
    client_identifier: String.t,
    user_class: String.t,
    request: list(String.t),
    require: list(String.t)
  }

  @typedoc """
  The dhcp_option type specifies the options that can be requested (nice to have ) and/or required by the DHCP client
  to accept the lease.
  """
  @type dhcp_option :: :"subnet-mask"
    | :"broadcast-address"
    | :"time-offset"
    | :"routers"
    | :"domain-name"
    | :"domain-search"
    | :"domain-name-servers"
    | :"host-name"

  @dhclient_conf_path "/etc/dhclientv4.conf"

  @doc """
  Default `dhclientv4.conf` path for this system.
  """
  @spec default_dhclient_conf_path :: Path.t
  def default_dhclient_conf_path do
    @dhclient_conf_path
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
  @spec set_vendor_class_id(dhclient_conf_t, Types.ifname, String.t) :: :ok
  def set_vendor_class_id(dhclient_conf, ifname, vendor_class_id) do
    GenServer.call(dhclient_conf, {:set, :vendor_class_identifier, ifname, vendor_class_id})
  end

  @spec set_client_id(dhclient_conf_t, Types.ifname, String.t) :: :ok
  def set_client_id(dhclient_conf, ifname, client_id) do
    GenServer.call(dhclient_conf, {:set, :client_identifier, ifname, client_id})
  end

  @spec set_user_class(dhclient_conf_t, Types.ifname, String.t) :: :ok
  def set_user_class(dhclient_conf, ifname, user_class) do
    GenServer.call(dhclient_conf, {:set, :user_class, ifname, user_class})
  end

  @spec set_request_list(dhclient_conf_t, Types.ifname, list(String.t)) :: :ok
  def set_request_list(dhclient_conf, ifname, request_list) do
    GenServer.call(dhclient_conf, {:set, :request, ifname, request_list})
  end

  @spec set_require_list(dhclient_conf_t, Types.ifname, list(String.t)) :: :ok
  def set_require_list(dhclient_conf, ifname, require_list) do
    GenServer.call(dhclient_conf, {:set, :require, ifname, require_list})
  end

  ## GenServer

  @typedoc "State of the server."
  @type state :: %{ifname: Types.ifname, ifmap: ifmap}

  @spec end_interface_text() :: String.t
  defp end_interface_text(), do: "}\n"

  @spec list_of_atoms_to_comma_separated_strings(list(dhcp_option), String.t, String.t) :: String.t
  defp list_of_atoms_to_comma_separated_strings(list, prefix, termination) do
    items_string =
      for item <- list do
        to_string(item)
      end
      |> Enum.join(", ")

    "  " <> prefix <> " " <> items_string <> ";\n"
  end

  @spec config_list_entry_text(atom(), Types.ifname, ifmap) :: String.t
  defp config_list_entry_text(item_name, ifname, ifmap) when is_atom(item_name) and item_name in [:request, :require] do
    case ifmap[item_name] do
      [] -> ""
      nil -> ""
      list -> list_of_atoms_to_comma_separated_strings(list, to_string(item_name), ";")
    end
  end

  @spec request_text(Types.ifname, ifmap) :: String.t
  defp request_text(ifname, ifmap) do
    #request subnet-mask, broadcast-address, time-offset, routers, domain-name, domain-name-servers, host-name;
    config_list_entry_text(:request, ifname, ifmap)
  end

  @spec require_text(Types.ifname, ifmap) :: String.t
  defp require_text(ifname, ifmap) do
    #require subnet-mask;
    config_list_entry_text(:require, ifname, ifmap)
  end


  defp dhclient_config_template(ifname, state) do
    """
    interface "<%= @interface %>" {
    <%= if @host_name do %>  send host-name "<%= @host_name %>";<% end %>
    <%= if @vendor_class_identifier do %>  send vendor-class-identifier "<%= @vendor_class_identifier %>";<% end %>
    <%= if @client_identifier do %>  send dhcp-client-identifier "<%= @client_identifier %>";<% end %>
    <%= if @user_class do %>  send user-class "<%= @user_class %>";<% end %>
    """
    <> request_text(ifname, state)
    <> require_text(ifname, state)
    <> end_interface_text()
  end

  @spec construct_contents({Types.ifname, ifmap} | any) :: String.t
  defp construct_contents({ifname, ifmap}) do
    Logger.debug("construct_contents[#{ifname}]: ifmap = #{inspect ifmap}")

    dhclient_config_template(ifname, ifmap)
    |> EEx.eval_string(
        assigns: [
            interface: ifname,
            vendor_class_identifier: nil,
            client_identifier: nil,
            user_class: nil,
            host_name: nil
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

  @spec write_dhclient_conf(String.t, %{filename: Path.t, ifmap: ifmap | map}) :: :ok
  defp write_dhclient_conf(ifname, state) do
    Logger.debug fn -> "#{__MODULE__}: write_dhclient_conf state = #{inspect state}" end

    contents = Enum.map(state.ifmap, &construct_contents/1)

    Logger.debug("+++++++ Contents +++++++")
    Logger.debug("#{inspect contents}")
    Logger.debug("++++++++++++++++++++++++")

    file_write(state.filename, contents)
  end

  @spec update_state(atom(), Types.ifname, String.t, state) :: state
  defp update_state(item_name, ifname, value, state)  do
    new_ifentry = state.ifmap
                    |> Map.get(ifname, %{})
                    |> Map.merge(%{item_name => value})

    %{state | ifmap: Map.put(state.ifmap, ifname, new_ifentry)}
  end

  def handle_call({:set, item_name, ifname, value}, _from, state) when is_atom(item_name) and
    item_name in [
      :host_name,
      :vendor_class_identifier,
      :client_identifier,
      :user_class,
      :request,
      :require
    ] do
    Logger.debug("handle_call item_name = #{inspect item_name} ifname = #{ifname}; value = #{inspect value} state = #{inspect state}")

    state = update_state(item_name, ifname, value, state)

    write_dhclient_conf(ifname, state)
    {:reply, :ok, state}
  end

  @doc false
  def init(filename) do
    state = %{filename: filename, ifmap: %{}}
    #write_dhclient_conf(state)
    Logger.debug("+++ #{__MODULE__}: filename = #{inspect filename}: state = #{inspect state}")
    {:ok, state}
  end

end
