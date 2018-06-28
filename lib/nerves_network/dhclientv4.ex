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

defmodule Nerves.Network.Dhclientv4 do
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
  Start and link a Dhclientv4 process for the specified interface (i.e., eth0,
  wlan0).
  """
  def start_link(_modname, args) do
    IO.puts "#{__MODULE__}: Dhclientv4 starting for args: #{inspect args}"
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
    IO.puts "Dhclientv4.stop ipid: #{inspect pid}"
    GenServer.stop(pid)
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
    [ipv4: runtime] = Application.get_env(:nerves_network, :dhclientv4, [])
     IO.puts "#{__MODULE__}: runtime options = #{inspect runtime}"
     runtime_lease_file(ifname, runtime) ++ runtime_pid_file(ifname, runtime)
  end

  def init(args) do
    {ifname, mode} = args
    Logger.info "#{__MODULE__}: Starting Dhclientv4 wrapper for ifname: #{inspect ifname} mode: #{inspect mode}"

    priv_path = :code.priv_dir(:nerves_network)
    port_path = "#{priv_path}/dhclientv4_wrapper"

    args = ["dhclient",
            "-4", #ipv4
            # "-sf", port_path, #The script to be invoked at the lease time
            "-v", "-d"
           ]
            ++ dhclient_runtime(ifname)
            ++ [ifname]

            port = Port.open({:spawn_executable, port_path},
            [{:args, args}, :exit_status, :stderr_to_stdout, {:line, 256}])

Logger.info "#{__MODULE__}: Dhclientv4 port: #{inspect  port}; args: #{inspect args}"

    {:ok, %{ifname: ifname, port: port}}
  end

  def terminate(_reason, state) do
    # Send the command to our wrapper to shut everything down.
    IO.puts "#{__MODULE__}: terminate..."
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

  #  Nerves.Network.Dhclientv4.handle_info({#Port<0.6423>, {:exit_status, 0}}, %{ifname: "eth1", port: #Port<0.6423>})
  def handle_info({pid, {:exit_status, exit_status}}, state) do
    IO.puts "#{__MODULE__}: handle_info pid = #{inspect pid}: exit_status = #{inspect exit_status}, state = #{inspect state}"
    "#{__MODULE__} Exit status: #{inspect exit_status} pid: #{inspect pid}"
    |> handle_dhclient(state)
  end

  def handle_info({_, {:data, {:eol, message}}}, state) do
    handle(message, state)
  end

  def handle_info({_, {:data, {_, message}}}, state) do
    IO.puts("In normal: got this message: #{inspect message}")
    handle(message, state)
  end

  def handle(message, state) do
    message
      |> List.to_string
      |> String.split(",")
      |> handle_dhclient(state)
  end

  defp handle_dhclient(["deconfig", ifname | _rest], state) do
    IO.puts "dhclient: deconfigure #{ifname}"

    Utils.notify(Nerves.Dhclientv4, state.ifname, :deconfig, %{ifname: ifname})
    {:noreply, state}
  end

  #Handling informational debug prints from the dhclient
  defp handle_dhclient([message], state) do
    IO.puts "#{__MODULE__} handle_dhclient args = #{inspect message} state = #{inspect state}"
    {:noreply, state}
  end

  #TODO: scribe PREINIT6 handler
  #[".../dhclient_wrapper", "PREINIT6", "eth1", "", "", ""] state = %{ifname: "eth1", port: #Port<0.5567>}

  defp handle_dhclient([_originator, "REBIND", ifname, ip, domain_search, dns, old_ip], state) do
    dnslist = String.split(dns, " ")
    IO.puts "dhclient: rebind #{ifname}: IPv4 = #{ip}, domain_search=#{domain_search}, dns=#{inspect dns} old_ip=#{inspect old_ip}"
    Utils.notify(Nerves.Dhclientv4, state.ifname, :rebind , %{ifname: ifname, ipv4_address: ip, ipv4_domain: domain_search, ipv4_nameservers: dnslist, old_ipv4_address: old_ip})
    {:noreply, state}
  end
  defp handle_dhclient([_originator, "BOUND", ifname, ip, domain_search, dns, old_ip], state) do
    dnslist = String.split(dns, " ")
    IO.puts "dhclient: bound #{ifname}: ipv4 = #{ip}, domain_search=#{domain_search}, dns=#{inspect dns}"
    Utils.notify(Nerves.Dhclientv4, state.ifname, :bound, %{ifname: ifname, ipv4_address: ip, ipv4_domain: domain_search, ipv4_nameservers: dnslist, old_ipv4_address: old_ip})
    {:noreply, state}
  end
  defp handle_dhclient([_originator, "RENEW", ifname, ip, domain_search, dns, old_ip], state) do
    dnslist = String.split(dns, " ")
    IO.puts "dhclient: renew #{ifname}"
    Utils.notify(Nerves.Dhclientv4, state.ifname, :renew, %{ifname: ifname, ipv4_address: ip, ipv4_domain: domain_search, ipv4_nameservers: dnslist, old_ipv4_address: old_ip})
    {:noreply, state}
  end

  defp handle_dhclient([_originator, "RELEASE", ifname, _ip, _domain_search, _dns, old_ip], state) do
    IO.puts "dhclient: release #{ifname}"
    Utils.notify(Nerves.Dhclientv4, state.ifname, :renew, %{ifname: ifname, old_ipv4_address: old_ip})
    {:noreply, state}
  end
  defp handle_dhclient([_originator, "EXPIRE", ifname, _ip, _domain_search, _dns, old_ip], state) do
    IO.puts "dhclient: expire #{ifname}"
    Utils.notify(Nerves.Dhclientv4, state.ifname, :expire, %{ifname: ifname, old_ipv4_address: old_ip})
    {:noreply, state}
  end
  defp handle_dhclient([_originator, "STOP", ifname, _ip, _domain_search, _dns, old_ip], state) do
    IO.puts "dhclient: stop #{ifname}"
    Utils.notify(Nerves.Dhclientv4, state.ifname, :stop, %{ifname: ifname, old_ipv4_address: old_ip})
    {:noreply, state}
  end

  defp handle_dhclient(something_else, state) do
    msg = List.foldl(something_else, "", &<>/2)
    IO.puts "dhclient: ignoring unhandled message: #{msg}"
    {:noreply, state}
  end
end
