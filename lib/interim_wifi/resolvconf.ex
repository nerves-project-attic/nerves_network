defmodule Nerves.InterimWiFi.Resolvconf do
  use GenServer

  @moduledoc """
  This module manages the contents of "/etc/resolv.conf". This file is used
  by the C library for resolving domain names and must be kept up-to-date
  as links go up and down. This module assumes exclusive ownership on
  "/etc/resolv.conf", so if any other code in the system tries to modify the
  file, their changes will be lost on the next update.
  """

  @resolvconf_path "/etc/resolv.conf"

  @doc """
  Return the default `resolve.conf` path for this system.
  """
  def default_resolvconf_path do
    @resolvconf_path
  end

  @doc """
  """
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
  def set_config(pid, ifname, options) when is_list(options) do
    set_config(pid, ifname, :maps.from_list(options))
  end
  def set_config(pid, ifname, options) when is_map(options) do
    GenServer.call(pid, {:set_config, ifname, options})
  end

  @doc """
  Set the search domain for non fully qualified domain name lookups.
  """
  def set_domain(pid, ifname, domain) do
    GenServer.call(pid, {:set_domain, ifname, domain})
  end

  @doc """
  Set the nameservers that were configured on this interface. These
  will be added to "/etc/resolv.conf" and replace any entries that
  were previously added for the specified interface.
  """
  def set_nameservers(pid, ifname, servers) when is_list(servers) do
    GenServer.call(pid, {:set_nameservers, ifname, servers})
  end

  @doc """
  Clear all entries in "/etc/resolv.conf" that are associated with
  the specified interface.
  """
  def clear(pid, ifname) do
    GenServer.call(pid, {:clear, ifname})
  end

  @doc """
  Completely clear out "/etc/resolv.conf".
  """
  def clear_all(pid) do
    GenServer.call(pid, :clear_all)
  end

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
  def handle_call({:set_config, ifname, ifentry}, _from, state) do
    state = %{state | ifmap: Map.put(state.ifmap, ifname, ifentry)}
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

  defp domain_text({_ifname, %{:domain => domain}}) when domain != "", do: "search #{domain}\n"
  defp domain_text(_), do: ""
  defp nameserver_text({_ifname, %{:nameservers => nslist}}) do
    for ns <- nslist, do: "nameserver #{ns}\n"
  end
  defp nameserver_text(_), do: ""

  defp write_resolvconf(state) do
    domains = Enum.map(state.ifmap, &domain_text/1)
    nameservers = Enum.map(state.ifmap, &nameserver_text/1)
    File.write!(state.filename, domains ++ nameservers)
  end
end
