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

  # Parsing config.exs entry of the following format: [dhclient: [lease_file: "/var/lib/dhclient4.leases", pid_file: "/var//run/dhclient4.pid"]]
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
            "-sf", port_path, #The script to be invoked at the lease time
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

  

  def handle(message, state) do
    IO.puts "This is message: #{inspect message}"
    message_s = List.to_string(message)
    IO.puts "This is message_s: #{inspect message_s}"
    message_l = String.split(message_s, ",")
    IO.puts "This is message_l: #{inspect message_l}"
    handle_dhclient(message_l, state)
  end

  def handle(message, state) do
    message
      |> List.to_string
      |> String.split(",")
      |> handle_dhclient(state)
  end

  @typedoc "State of the GenServer."
  @type state :: %{ifname: Types.ifname, port: port}

  @typedoc "Message from the dhclientv4 port."
  @type dhclientv4_wrapper_event :: [...] # we can do better.

  @typedoc "Event from the dhclientv4 server to be sent via SystemRegistry."
  @type event :: :deconfig | :bound | :renew | :leasefail | :reboot | :nak

  @spec handle_dhclient(dhclientv4_wrapper_event, state) :: {:noreply, state}
  defp handle_dhclient(["deconfig", ifname | _rest], state) do
    IO.puts "dhclientv4: deconfigure #{ifname}"

    Utils.notify(Nerves.Dhclientv4, state.ifname, :deconfig, %{ifname: ifname})
    {:noreply, state}
  end

  defp handle_dhclient(["BOUND", ifname, ip, broadcast, subnet, router, domain, dns], state) do
    dnslist = String.split(dns, " ")
    IO.puts "dhclientv4: bound #{ifname}: IP=#{ip}, dns=#{inspect dns} router=#{inspect router}"
    Utils.notify(Nerves.Dhclientv4, state.ifname, :bound, %{ifname: ifname, ipv4_address: ip, ipv4_broadcast: broadcast, ipv4_subnet_mask: subnet, ipv4_gateway: router, domain: domain, nameservers: dnslist})
    {:noreply, state}
  end

  defp handle_dhclient(["REBOOT", ifname, ip, broadcast, subnet, router, domain, dns], state) do
    dnslist = String.split(dns, " ")
    IO.puts "dhclientv4: reboot #{ifname}: IP=#{ip}, dns=#{inspect dns} router=#{inspect router}"
    Utils.notify(Nerves.Dhclientv4, state.ifname, :reboot, %{ifname: ifname, ipv4_address: ip, ipv4_broadcast: broadcast, ipv4_subnet_mask: subnet, ipv4_gateway: router, domain: domain, nameservers: dnslist})
    {:noreply, state}
  end

  defp handle_dhclient(["RENEW", ifname, ip, broadcast, subnet, router, domain, dns], state) do
    dnslist = String.split(dns, " ")
    IO.puts "dhclientv4: renew #{ifname}: IP=#{ip}, dns=#{inspect dns} router=#{inspect router}"
    Utils.notify(Nerves.Dhclientv4, state.ifname, :renew, %{ifname: ifname, ipv4_address: ip, ipv4_broadcast: broadcast, ipv4_subnet_mask: subnet, ipv4_gateway: router, domain: domain, nameservers: dnslist})
    {:noreply, state}
  end

  defp handle_dhclient(["REBIND", ifname, ip, broadcast, subnet, router, domain, dns], state) do
    dnslist = String.split(dns, " ")
    IO.puts "dhclientv4: rebind #{ifname}: IP=#{ip}, dns=#{inspect dns} router=#{inspect router}"
    Utils.notify(Nerves.Dhclientv4, state.ifname, :rebind, %{ifname: ifname, ipv4_address: ip, ipv4_broadcast: broadcast, ipv4_subnet_mask: subnet, ipv4_gateway: router, domain: domain, nameservers: dnslist})
    {:noreply, state}
  end

  defp handle_dhclient(["leasefail", ifname, _ip, _broadcast, _subnet, _router, _domain, _dns, message], state) do
    IO.puts "dhclientv4: #{ifname}: leasefail #{message}"
    Utils.notify(Nerves.Dhclientv4, state.ifname, :leasefail, %{ifname: ifname, message: message})
    {:noreply, state}
  end

  defp handle_dhclient(["nak", ifname, _ip, _broadcast, _subnet, _router, _domain, _dns, message], state) do
    IO.puts "dhclientv4: #{ifname}: NAK #{message}"
    Utils.notify(Nerves.Dhclientv4, state.ifname, :nak, %{ifname: ifname, message: message})
    {:noreply, state}
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

  defp handle_dhclient(something_else, state) do
    msg = List.foldl(something_else, "", &<>/2)
    IO.puts "dhclient: ignoring unhandled message: #{msg}"
    {:noreply, state}
  end
end
