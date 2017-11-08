# Copyright 2014-2017 Frank Hunleth
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

defmodule Nerves.Network.Udhcpc do
  use GenServer
  require Logger
  alias Nerves.Network.{Types, Utils}

  @typedoc "Instance of this server."
  @type udhcpc :: GenServer.server

  @moduledoc """
  This module interacts with `udhcpc` to interact with DHCP servers.
  """

  @doc """
  Start and link a Udhcpc process for the specified interface (i.e., eth0,
  wlan0).
  """
  @spec start_link(Types.ifname) :: GenServer.on_start()
  def start_link(ifname) do
    Logger.debug fn -> "#{__MODULE__}: Starting Udhcpc for #{inspect ifname}" end
    GenServer.start_link(__MODULE__, ifname)
  end

  @doc """
  Notify the DHCP server to release the IP address currently assigned to
  this interface. After calling this, be sure to disassociate the IP address
  from the interface so that packets don't accidentally get sent or processed.
  """
  @spec release(udhcpc) :: :ok
  def release(pid) do
    GenServer.call(pid, :release)
  end

  @doc """
  Renew the lease on the IP address with the DHCP server.
  """
  @spec renew(udhcpc) :: :ok
  def renew(pid) do
    GenServer.call(pid, :renew)
  end

  @doc """
  Stop the dhcp client
  """
  @spec stop(udhcpc) :: :ok
  def stop(pid) do
    GenServer.stop(pid)
  end

  def init(ifname) do
    priv_path = :code.priv_dir(:nerves_network)
    port_path = "#{priv_path}/udhcpc_wrapper"
    args = ["udhcpc",
            "--interface", ifname,
            "--script", port_path,
            "--foreground",
            "-x", "hostname:#{hostname()}"]
    port = Port.open({:spawn_executable, port_path},
                     [{:args, args}, :exit_status, :stderr_to_stdout, {:line, 256}])
    {:ok, %{ifname: ifname, port: port}}
  end

  def terminate(_reason, state) do
    # Send the command to our wrapper to shut everything down.
    Port.command(state.port, <<3>>);
    Port.close(state.port)
    :ok
  end

  def handle_call(:renew, _from, state) do
    # If we send a byte with the value 1 to the wrapper, it will turn it into
    # a SIGUSR1 for udhcpc so that it renews the IP address.
    Port.command(state.port, <<1>>);
    {:reply, :ok, state}
  end

  def handle_call(:release, _from, state) do
    Port.command(state.port, <<2>>);
    {:reply, :ok, state}
  end

  def handle_info({_, {:data, {:eol, message}}}, state) do
    message
      |> List.to_string
      |> String.split(",")
      |> handle_udhcpc(state)
  end

  @typedoc "State of the GenServer."
  @type state :: %{ifname: Types.ifname, port: port}

  @typedoc "Message from the udhcpc port."
  @type udhcpc_wrapper_event :: [...] # we can do better.

  @typedoc "Event from the udhcpc server to be sent via SystemRegistry."
  @type event :: :deconfig | :bound | :renew | :leasefail | :nak

  @spec handle_udhcpc(udhcpc_wrapper_event, state) :: {:noreply, state}
  defp handle_udhcpc(["deconfig", ifname | _rest], state) do
    Logger.debug "udhcpc: deconfigure #{ifname}"

    Utils.notify(Nerves.Udhcpc, state.ifname, :deconfig, %{ifname: ifname})
    {:noreply, state}
  end

  defp handle_udhcpc(["bound", ifname, ip, broadcast, subnet, router, domain, dns, _message], state) do
    dnslist = String.split(dns, " ")
    Logger.debug "udhcpc: bound #{ifname}: IP=#{ip}, dns=#{inspect dns} router=#{inspect router}"
    Utils.notify(Nerves.Udhcpc, state.ifname, :bound, %{ifname: ifname, ipv4_address: ip, ipv4_broadcast: broadcast, ipv4_subnet_mask: subnet, ipv4_gateway: router, domain: domain, nameservers: dnslist})
    {:noreply, state}
  end

  defp handle_udhcpc(["renew", ifname, ip, broadcast, subnet, router, domain, dns, _message], state) do
    dnslist = String.split(dns, " ")
    Logger.debug "udhcpc: renew #{ifname}: IP=#{ip}, dns=#{inspect dns} router=#{inspect router}"
    Utils.notify(Nerves.Udhcpc, state.ifname, :renew, %{ifname: ifname, ipv4_address: ip, ipv4_broadcast: broadcast, ipv4_subnet_mask: subnet, ipv4_gateway: router, domain: domain, nameservers: dnslist})
    {:noreply, state}
  end

  defp handle_udhcpc(["leasefail", ifname, _ip, _broadcast, _subnet, _router, _domain, _dns, message], state) do
    Logger.debug "udhcpc: #{ifname}: leasefail #{message}"
    Utils.notify(Nerves.Udhcpc, state.ifname, :leasefail, %{ifname: ifname, message: message})
    {:noreply, state}
  end

  defp handle_udhcpc(["nak", ifname, _ip, _broadcast, _subnet, _router, _domain, _dns, message], state) do
    Logger.debug "udhcpc: #{ifname}: NAK #{message}"
    Utils.notify(Nerves.Udhcpc, state.ifname, :nak, %{ifname: ifname, message: message})
    {:noreply, state}
  end

  defp handle_udhcpc(_something_else, state) do
    {:noreply, state}
  end

  @spec hostname :: String.t
  defp hostname do
    {:ok, hostname} = :inet.gethostname()
    to_string(hostname)
    |> String.trim
  end
end
