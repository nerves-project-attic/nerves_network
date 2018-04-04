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
    search: String.t,
    nameservers: [Types.ip_address],
    static_nameservers: [Types.ip_address],
    ipv6_nameservers: [Types.ip_address]
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
    * `:search` - a search list of domains :domain and :search are mutually exclusive the last in the resolv.conf file wins
                  search is always put last
    * `:nameservers` - a list of IP addresses of name servers

  Options can be specified either as a keyword list or as a map. E.g.,

    %{domain: "example.com", search: "example.com ipv6.example.com", nameservers: ["8.8.8.8", "8.8.4.4"]}
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
  Sets the static (manually configured) search domains. The 'static' search domains take recedence over ones
  set by DHCPv4 and DHCPv6 clients.
  """
  @spec set_static_domains(resolvconf, Types.ifname, list(String.t)) :: :ok
  def set_static_domains(resolv_conf, ifname, domains) do
    GenServer.call(resolv_conf, {:set_static_domains, ifname, domains})
  end

  def set_static_domains(ifname, domains) do
    GenServer.call(__MODULE__, {:set_static_domains, ifname, domains})
  end

  @spec set_static_nameservers(resolvconf, Types.ifname, list(String.t)) :: :ok
  def set_static_nameservers(resolv_conf, ifname, servers) do
    GenServer.call(resolv_conf, {:set_static_nameservers, ifname, servers})
  end

  @spec set_static_nameservers(Types.ifname, list(String.t)) :: :ok
  def set_static_nameservers(ifname, servers) do
    GenServer.call(__MODULE__, {:set_static_nameservers, ifname, servers})
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

  @doc """
  Read current settings in "/etc/resolv.conf".
  """
  @spec settings(resolvconf, Types.ifname) :: ifmap
  def settings(resolv_conf, ifname) do
    GenServer.call(resolv_conf, {:settings, ifname})
  end

  @doc """
  Read current settings in "/etc/resolv.conf".
  """
  @spec settings(Types.ifname) :: ifmap
  def settings(ifname) do
    GenServer.call(__MODULE__, {:settings, ifname})
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

  def handle_call({:set_static_domains, ifname, domains}, _from, state) do
    Logger.debug fn -> "#{__MODULE__}: handle_call: :set_static_domains old_state = #{inspect state}" end
    new_ifentry = state.ifmap
                    |> Map.get(ifname, %{})
                    |> Map.merge(%{:static_domains => domains})

    state = %{state | ifmap: Map.put(state.ifmap, ifname, new_ifentry)}

    Logger.debug fn -> "#{__MODULE__}: handle_call: :set_static_domains new_state = #{inspect state}" end
    write_resolvconf(state)
    {:reply, :ok, state}
  end

  def handle_call({:set_static_nameservers, ifname, servers}, _from, state) do
    Logger.debug fn -> "#{__MODULE__}: handle_call: :set_static_nameservers old_state = #{inspect state}" end
    #Remove the old static_nameservers from the nameservers superposition
    ifmap = state.ifmap |> Map.get(ifname, %{})

    current_static_nameservers = Map.get(ifmap, :static_nameservers, [])
    current_nameservers        = Map.get(ifmap, :nameservers, [])

    nameservers = current_nameservers -- current_static_nameservers

    new_ifentry = Map.merge(ifmap, %{:nameservers => nameservers, :static_nameservers => servers})
    new_state = %{state | ifmap: Map.put(state.ifmap, ifname, new_ifentry)}

    write_resolvconf(new_state)
    {:reply, :ok, new_state}
  end

  def handle_call({:set_search, ifname, domains}, _from, state) do
    state = put_in(state[ifname].search, domains)
    write_resolvconf(state)
    {:reply, :ok, state}
  end

  def handle_call({:set_nameservers, ifname, nameservers}, _from, state) do
    state = put_in(state[ifname].nameservers, nameservers)
    write_resolvconf(state)
    {:reply, :ok, state}
  end

  #Elixir.Nerves.Network.Resolvconf: state = %{filename: "/home/motyl/resolv.conf", ifmap: %{"ens33" => %{domain: "eur.gad.schneider-electric.com", ifname: "ens33", ipv4_address: "10.216.251.72", ipv4_broadcast: "", ipv4_gateway: "10.216.251.1", ipv4_subnet_mask: "255.255.255.128", nameservers: ["10.156.118.9", "10.198.90.15"]}}, nameservers: ["10.156.118.9", "10.198.90.15"], search: "eur.gad.schneider-electric.com"}; retval = nil
  def handle_call({:settings, ifname}, _from, state) do
    state  = read_resolvconf(ifname, state)
    {:reply, {:ok, state[:ifmap][ifname]}, state}
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

  defp append_domain(search_string, ""), do: search_string
  defp append_domain(search_string, "\n"), do: search_string <> "\n"
  defp append_domain(search_string, domain) do
    search_string <> " #{domain}"
  end

  @spec domain_text({Types.ifname, ifmap} | any) :: String.t
  defp domain_text({_ifname, ifmap = %{:static_domains => static_domains}}) when is_list(static_domains) and static_domains != nil do
    ipv4_domain_string    = ifmap[:domain] || ""
    ipv6_domain_string    = ifmap[:ipv6_domain] || ""
    case static_domains do
      [] -> static_domains_string = Enum.join(static_domains, " ")
        "search  #{static_domains_string}"
         |> append_domain(ipv4_domain_string)
          |> append_domain(ipv6_domain_string)
         |> String.trim()
         |> append_domain("\n")
      _ -> ""
    end
  end
  defp domain_text({_ifname, %{:domain => domain, :ipv6_domain => ipv6_domain}}) when domain != "" or ipv6_domain != "", do: "search #{domain} #{ipv6_domain}\n"
  defp domain_text({_ifname, %{:domain => domain}}) when domain != "", do: "search #{domain}\n"
  defp domain_text({_ifname, %{:ipv6_domain => domain}}) when domain != "", do: "search #{domain}\n"
  defp domain_text(_), do: ""


  @spec nameserver_text({Types.ifname, ifmap} | any) :: [String.t]
  defp nameserver_text({_ifname, %{:nameservers => nslist}}) do
    for ns <- nslist, do: "nameserver #{ns}\n"
  end
  defp nameserver_text(_), do: ""

  @spec static_nameserver_text({Types.ifname, ifmap} | any) :: [String.t]
  defp static_nameserver_text({_ifname, %{:static_nameservers => nslist}}) do
    for ns <- nslist, do: "nameserver #{ns}\n"
  end
  defp static_nameserver_text(_), do: ""

  defp nameserver6_text({_ifname, %{:ipv6_nameservers => nslist}}) do
    for ns <- nslist, do: "nameserver #{ns}\n"
  end
  defp nameserver6_text(_), do: ""

  #By default there are 3 nameservers supported by the Linux resolver. A typical configuration (for IPv4/IPv6 dual stack) would look like this:
  #/etc/resolv.conf:
  #  nameserver 8.8.8.8
  #  nameserver 8.8.4.4
  #  nameserver 2001:4860:4860::8888
  #  nameserver 2001:4860:4860::8844
  #
  # We allow as well to manually using the :static_nameservers entry in the state. Those will be added to the /etc/resolv.conf file
  # prior to IPv4 and IPv6 nameserver entries in order to take precedence. This is to support 'static' IPv4/IPv6 settings.
  # The feature can be used to provide a 'static' nameserver entry on the top of ones dynamically configured by either DHCPv4 and/or DHCPv6.
  @spec write_resolvconf(%{filename: Path.t, ifmap: ifmap | map}) :: :ok
  defp write_resolvconf(state) do
    Logger.debug fn -> "#{__MODULE__}: write_resolvconf state = #{inspect state}" end

    domains     = Enum.map(state.ifmap, &domain_text/1)

    #Static Nameservers
    static_nameservers =  Enum.map(state.ifmap, &static_nameserver_text/1)

    #Common part IPv4/IPv6/Static
    nameservers_super = Enum.map(state.ifmap, &nameserver_text/1)

    #IPv6 part - must preceed the IPv4 nameservers
    nameservers6 = Enum.map(state.ifmap, &nameserver6_text/1)

    #We do not need to store nameservers that are in static_nameservers or ipv6_nameservers. nameservers field reports all set-up nameservers and becomes a superposition
    #After reading the /etc/resolv.conf file - calling Nerves.Network.Resolvconf.settings(ifname) function
    nameservers = (nameservers_super -- static_nameservers) -- nameservers6

    Logger.debug fn -> "#{__MODULE__}: static_nameservers = #{inspect static_nameservers}" end
    Logger.debug fn -> "#{__MODULE__}: nameservers        = #{inspect nameservers}" end
    Logger.debug fn -> "#{__MODULE__}: nameservers6       = #{inspect nameservers6}" end

    File.write!(state.filename, domains ++ static_nameservers ++ nameservers ++ nameservers6)
  end


  @spec entry_to_map(String.t, String.t, ifmap) :: ifmap
  #domain and search entries are mutually exclusive man (5) resolv.conf. The last entry in the resolv.conf file wins
  defp entry_to_map("domain", value, _map), do: %{search: value}
  defp entry_to_map("search", value, _map), do: %{search: value}
  defp entry_to_map("nameserver", value, map) do
    nameservers = map[:"nameservers"]
    case nameservers do
      nil -> %{nameservers: [value]}
      # We are doing it slow way to preserve the order of occurrence of nameserver entries - up to 3 such entries are supported
      _ -> %{nameservers: nameservers ++ [value]}
    end
  end
  defp entry_to_map(_, _value, _map), do: %{}

  @spec split_line(String.t, ifmap) :: ifmap
  defp split_line(line, map) do
    [entry, value] =
      case String.split(line, ~r{\s+}, parts: 2) do
        [entry, value] -> [entry, value]
        _ -> ["", ""]
      end

    Map.merge(map, entry_to_map(entry, value, map))
  end

  @spec read_resolvconf(Types.ifname, ifmap) :: ifmap
  def read_resolvconf(ifname, state) do
    Logger.debug fn -> "#{__MODULE__}: read_resolv_conf" end

    {:ok, data} = File.read(state.filename)

    lines =
      data
        |> String.split("\n")

    #We want each entry in the resolv.conf file to be split into ["key", "value"]
    map =
      Enum.reduce(lines, %{}, fn(x, map) -> split_line(x, map) end)

    ifmap_old  = state[:ifmap]
    config_old = ifmap_old[ifname] || %{}

    config_new =
    config_old
      |> Map.merge(map)

    Map.merge(state, %{ifmap: %{ifname => config_new}})
  end
end
