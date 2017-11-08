defmodule Nerves.Network.Resolvconf do
  use GenServer
  alias Nerves.Network.Types
  require Logger

  @moduledoc """
  This module manages the contents of "/etc/resolv.conf". This file is used
  by the C library for resolving domain names and must be kept up-to-date
  as links go up and down. This module assumes exclusive ownership on
  "/etc/resolv.conf", so if any other code in the system tries to modify the
  file, their changes will be lost on the next update.
  """

  @type resolvconf :: GenServer.server

  @typedoc "Settings for resolvconf"
  @type ifmap :: %{
    domain: String.t,
    nameservers: [Types.ip_address]
  }

  @resolvconf_path "/etc/resolv.conf"

  @doc """
  Default `resolv.conf` path for this system.
  """
  @spec default_resolvconf_path :: Path.t
  def default_resolvconf_path do
    @resolvconf_path
  end

  @doc """
  Start the resolv.conf manager.
  """
  @spec start_link(Path.t, GenServer.options) :: GenServer.on_start
  def start_link(resolvconf_path \\ @resolvconf_path, opts \\ []) do
    GenServer.start_link(__MODULE__, resolvconf_path, opts)
  end

  @doc """
  Set all of the options for this interface in one shot. The following
  options are available:

    * `:domain` - the local domain name
    * `:nameservers` - a list of IP addresses of name servers

  Options can be specified either as a keyword list or as a map. E.g.,

    %{domain: "example.com", nameservers: ["8.8.8.8", "8.8.4.4"]}
  """
  @spec setup(resolvconf, Types.ifname, Nerves.Network.setup_settings | Types.udhcp_info) :: :ok
  def setup(resolv_conf, ifname, options) when is_list(options) do
    setup(resolv_conf, ifname, :maps.from_list(options))
  end

  def setup(resolv_conf, ifname, options) when is_map(options) do
    GenServer.call(resolv_conf, {:setup, ifname, options})
  end

  @doc """
  Set the search domain for non fully qualified domain name lookups.
  """
  @spec set_domain(resolvconf, Types.ifname, String.t) :: :ok
  def set_domain(resolv_conf, ifname, domain) do
    GenServer.call(resolv_conf, {:set_domain, ifname, domain})
  end

  @doc """
  Set the nameservers that were configured on this interface. These
  will be added to "/etc/resolv.conf" and replace any entries that
  were previously added for the specified interface.
  """
  @spec set_nameservers(resolvconf, Types.ifname, [Types.ip_address]) :: :ok
  def set_nameservers(resolv_conf, ifname, servers) when is_list(servers) do
    GenServer.call(resolv_conf, {:set_nameservers, ifname, servers})
  end

  @doc """
  Clear all entries in "/etc/resolv.conf" that are associated with
  the specified interface.
  """
  @spec clear(resolvconf, Types.ifname) :: :ok
  def clear(resolv_conf, ifname) do
    GenServer.call(resolv_conf, {:clear, ifname})
  end

  @doc """
  Completely clear out "/etc/resolv.conf".
  """
  @spec clear_all(resolvconf) :: :ok
  def clear_all(resolv_conf) do
    GenServer.call(resolv_conf, :clear_all)
  end

  ## GenServer

  @typedoc "State of the server."
  @type state :: %{ifname: Types.ifname, ifmap: ifmap}

  def init(filename) do
    state = %{filename: filename, ifmap: %{}}
    write_resolvconf(state)
    {:ok, state}
  end

  def handle_call({:set_domain, ifname, domain}, _from, state) do
    state = put_in(state[ifname].domain, domain)
    write_resolvconf(state)
    {:reply, :ok, state}
  end

  def handle_call({:set_nameservers, ifname, nameservers}, _from, state) do
    state = put_in(state[ifname].nameservers, nameservers)
    write_resolvconf(state)
    {:reply, :ok, state}
  end

  def handle_call({:setup, ifname, ifentry}, _from, state) do
    new_ifentry = state.ifmap
                    |> Map.get(ifname, %{})
                    |> Map.merge(ifentry)
    state = %{state | ifmap: Map.put(state.ifmap, ifname, new_ifentry)}
    write_resolvconf(state)
    {:reply, :ok, state}
  end

  def handle_call({:clear, ifname}, _from, state) do
    state = %{state | ifmap: Map.delete(state.ifmap, ifname)}
    write_resolvconf(state)
    {:reply, :ok, state}
  end

  def handle_call(:clear_all, _from, state) do
    state = %{state | ifmap: %{}}
    write_resolvconf(state)
    {:reply, :ok, state}
  end

  @spec domain_text({Types.ifname, ifmap} | any) :: String.t
  defp domain_text({_ifname, %{:domain => domain, :ipv6_domain => ipv6_domain}}) when domain != "" or ipv6_domain != "", do: "search #{domain} #{ipv6_domain}\n"
  defp domain_text({_ifname, %{:domain => domain}}) when domain != "", do: "search #{domain}\n"
  defp domain_text({_ifname, %{:ipv6_domain => domain}}) when domain != "", do: "search #{domain}\n"
  defp domain_text(_), do: ""

  @spec nameserver_text({Types.ifname, ifmap} | any) :: [String.t]
  defp nameserver_text({_ifname, %{:nameservers => nslist}}) do
    for ns <- nslist, do: "nameserver #{ns}\n"
  end
  defp nameserver_text(_), do: ""

  @spec write_resolvconf(%{filename: Path.t, ifmap: ifmap | map}) :: :ok
  defp domain6_text({_ifname, %{:ipv6_domain => domain}}) when domain != "", do: "search #{domain}\n"
  defp domain6_text(_), do: ""
  defp nameserver6_text({_ifname, %{:ipv6_nameservers => nslist}}) do
    for ns <- nslist, do: "nameserver #{ns}\n"
  end
  defp nameserver6_text(_), do: ""

  defp write_resolvconf(state) do
    Logger.debug fn -> "#{__MODULE__}: write_resolvconf state = #{inspect state}" end

    #IPv4 part
    domains     = Enum.map(state.ifmap, &domain_text/1)
    nameservers = Enum.map(state.ifmap, &nameserver_text/1)

    #IPv6 part
    nameservers6 = Enum.map(state.ifmap, &nameserver6_text/1)

    File.write!(state.filename, domains ++ nameservers ++ nameservers6)
  end
end
