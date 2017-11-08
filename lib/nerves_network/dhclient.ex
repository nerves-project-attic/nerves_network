# Copyright 2014 LKC Technologies, Inc.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
# http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

defmodule Nerves.Network.Dhclient do
  use GenServer
  require Logger
  alias Nerves.Network.Utils

  @renew     1
  @release   2
  @terminate 3

  @moduledoc """
  This module interacts with `dhclient` to interact with DHCP servers.
  """

  def start_link(args), do: start_link(__MODULE__, args)

  @doc """
  Start and link a Dhclient process for the specified interface (i.e., eth0,
  wlan0).
  """
  def start_link(_modname, args) do
    Logger.debug fn -> "#{__MODULE__}: Dhclient starting for args: #{inspect args}" end
    GenServer.start_link(__MODULE__, args)
  end

  @doc """
  Notify the DHCP server to release the IP address currently assigned to
  this interface. After calling this, be sure to disassociate the IP address
  from the interface so that packets don't accidentally get sent or processed.
  """
  def release(pid) do
    GenServer.call(pid, :release)
  end

  @doc """
  Renew the lease on the IP address with the DHCP server.
  """
  def renew(pid) do
    GenServer.call(pid, :renew)
  end

  @doc """
  Stop the dhcp client
  """
  def stop(pid) do
    Logger.debug fn -> "Dhclient.stop ipid: #{inspect pid}" end
    GenServer.stop(pid)
  end

  defp dhclient_mode_args(:stateful) do
    []
  end

  defp dhclient_mode_args(:stateless) do
    ["-S"]
  end

  defp append_ifname(input_str, ifname) do
    input_str <> "." <> ifname
  end

  defp runtime_lease_file(ifname, runtime) do
      if Keyword.has_key?(runtime, :lease_file) do
        [ "-lf", Keyword.get(runtime, :lease_file) |> append_ifname(ifname) ]
      else
        []
      end
  end

  defp runtime_pid_file(ifname, runtime) do
      if Keyword.has_key?(runtime, :pid_file) do
        [ "-pf", Keyword.get(runtime, :pid_file) |> append_ifname(ifname) ]
      else
        []
      end
  end

  # Parsing config.exs entry of the following format: [dhclient: [lease_file: "/var/system/dhclient6.leases", pid_file: "/var/system/dhclient6.pid"]]
  defp dhclient_runtime(ifname) do
    [ipv6: runtime] = Application.get_env(:nerves_network, :dhclient, [])
     Logger.debug fn -> "#{__MODULE__}: runtime options = #{inspect runtime}" end
     runtime_lease_file(ifname, runtime) ++ runtime_pid_file(ifname, runtime)
  end

  def init(args) do
    {ifname, mode} = args
    Logger.info fn -> "#{__MODULE__}: Starting Dhclient wrapper for ifname: #{inspect ifname} mode: #{inspect mode}" end

    priv_path = :code.priv_dir(:nerves_network)
    port_path = "#{priv_path}/dhclient_wrapper"

    args = ["dhclient",
            "-6", #IPv6
            "-sf", port_path, #The script to be invoked at the lease time
            "-q", "-d"
           ]
            ++ dhclient_mode_args(mode)
            ++ dhclient_runtime(ifname)
            ++ [ifname]

    port = Port.open({:spawn_executable, port_path},
                     [{:args, args}, :exit_status, :stderr_to_stdout, {:line, 256}])

    Logger.info fn -> "#{__MODULE__}: Dhclient port: #{inspect  port}; args: #{inspect args}" end

    {:ok, %{ifname: ifname, port: port}}
  end

  def terminate(_reason, state) do
    # Send the command to our wrapper to shut everything down.
    Logger.debug fn -> "#{__MODULE__}: terminate..." end
    Port.command(state.port, <<@terminate>>);
    Port.close(state.port)
    :ok
  end

  def handle_call(:renew, _from, state) do
    # If we send a byte with the value 1 to the wrapper, it will turn it into
    # a SIGUSR1 for dhclient so that it renews the IP address.
    Port.command(state.port, <<@renew>>);
    {:reply, :ok, state}
  end

  def handle_call(:release, _from, state) do
    Port.command(state.port, <<@release>>);
    {:reply, :ok, state}
  end

  #  Nerves.Network.Dhclient.handle_info({#Port<0.6423>, {:exit_status, 0}}, %{ifname: "eth1", port: #Port<0.6423>})
  def handle_info({pid, {:exit_status, exit_status}}, state) do
    Logger.debug fn -> "#{__MODULE__}: handle_info pid = #{inspect pid}: exit_status = #{inspect exit_status}, state = #{inspect state}" end
    "#{__MODULE__} Exit status: #{inspect exit_status} pid: #{inspect pid}"
    |> handle_dhclient(state)
  end

  def handle_info({_, {:data, {:eol, message}}}, state) do
    message
      |> List.to_string
      |> String.split(",")
      |> handle_dhclient(state)
  end

  defp handle_dhclient(["deconfig", ifname | _rest], state) do
    Logger.debug "dhclient: deconfigure #{ifname}"

    Utils.notify(Nerves.Dhclient, state.ifname, :deconfig, %{ifname: ifname})
    {:noreply, state}
  end

  defp notify_dhclient(ifname, event, config, state) do
    {:noreply, state}
  end

  #Handling informational debug prints from the dhclient
  defp handle_dhclient([message], state) do
    Logger.debug fn -> "#{__MODULE__} handle_dhclient args = #{inspect message} state = #{inspect state}" end
    {:noreply, state}
  end

  #TODO: scribe PREINIT6 handler
  #[".../dhclient_wrapper", "PREINIT6", "eth1", "", "", ""] state = %{ifname: "eth1", port: #Port<0.5567>}

  defp handle_dhclient([_originator, "REBIND6", ifname, ip, domain_search, dns, old_ip], state) do
    dnslist = String.split(dns, " ")
    Logger.debug fn -> "dhclient: rebind #{ifname}: IPv6 = #{ip}, domain_search=#{domain_search}, dns=#{inspect dns} old_ip=#{inspect old_ip}" end
    Utils.notify(Nerves.Dhclient, state.ifname, :rebind , %{ifname: ifname, ipv6_address: ip, ipv6_domain: domain_search, ipv6_nameservers: dnslist, old_ipv6_address: old_ip})
    {:noreply, state}
  end
  defp handle_dhclient([_originator, "BOUND6", ifname, ip, domain_search, dns, old_ip], state) do
    dnslist = String.split(dns, " ")
    Logger.debug fn -> "dhclient: bound #{ifname}: IPv6 = #{ip}, domain_search=#{domain_search}, dns=#{inspect dns}" end
    Utils.notify(Nerves.Dhclient, state.ifname, :bound, %{ifname: ifname, ipv6_address: ip, ipv6_domain: domain_search, ipv6_nameservers: dnslist, old_ipv6_address: old_ip})
    {:noreply, state}
  end
  defp handle_dhclient([_originator, "RENEW6", ifname, ip, domain_search, dns, old_ip], state) do
    dnslist = String.split(dns, " ")
    Logger.debug "dhclient: renew #{ifname}"
    Utils.notify(Nerves.Dhclient, state.ifname, :renew, %{ifname: ifname, ipv6_address: ip, ipv6_domain: domain_search, ipv6_nameservers: dnslist, old_ipv6_address: old_ip})
    {:noreply, state}
  end

  defp handle_dhclient([_originator, "RELEASE6", ifname, _ip, _domain_search, _dns, old_ip], state) do
    Logger.debug fn -> "dhclient: release #{ifname}" end
    Utils.notify(Nerves.Dhclient, state.ifname, :renew, %{ifname: ifname, old_ipv6_address: old_ip})
    {:noreply, state}
  end
  defp handle_dhclient([_originator, "EXPIRE6", ifname, _ip, _domain_search, _dns, old_ip], state) do
    Logger.debug fn -> "dhclient: expire #{ifname}" end
    Utils.notify(Nerves.Dhclient, state.ifname, :expire, %{ifname: ifname, old_ipv6_address: old_ip})
    {:noreply, state}
  end
  defp handle_dhclient([_originator, "STOP6", ifname, _ip, _domain_search, _dns, old_ip], state) do
    Logger.debug fn -> "dhclient: stop #{ifname}" end
    Utils.notify(Nerves.Dhclient, state.ifname, :stop, %{ifname: ifname, old_ipv6_address: old_ip})
    {:noreply, state}
  end

  defp handle_dhclient(_something_else, state) do
    #msg = List.foldl(something_else, "", &<>/2)
    #Logger.debug "dhclient: ignoring unhandled message: #{msg}"
    {:noreply, state}
  end
end
