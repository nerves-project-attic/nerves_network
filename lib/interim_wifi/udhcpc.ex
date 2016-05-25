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

defmodule Nerves.InterimWiFi.Udhcpc do
  use GenServer
  require Logger

  @moduledoc """
  This module interacts with `udhcpc` to interact with DHCP servers.
  """

  @doc """
  Start and link a Udhcpc process for the specified interface (i.e., eth0,
  wlan0).
  """
  def start_link(ifname) do
    GenServer.start_link(__MODULE__, ifname)
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
    GenServer.cast(pid, :stop)
  end

  def init(ifname) do
    priv_path = :code.priv_dir(:nerves_interim_wifi)
    port_path = "#{priv_path}/udhcpc_wrapper"
    args = ["udhcpc",
            "--interface", ifname,
            "--script", port_path,
            "--foreground"]
          |> add_hostname_arg(hostname)
    port = Port.open({:spawn_executable, port_path},
                     [{:args, args}, :exit_status, :stderr_to_stdout, {:line, 256}])
    {:ok, %{ifname: ifname, port: port}}
  end

  defp add_hostname_arg(args, "noname"), do: args
  defp add_hostname_arg(args, name), do: args ++ ["-x", "hostname:#{name}"]

  def terminate(_reason, state) do
    # Closing Erlang ports just turns off I/O. That's not good enough for
    # udhcpc. It needs to be killed.
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

  def handle_cast(:stop, state) do
    {:stop, :normal, state}
  end

  def handle_info({_, {:data, {:eol, message}}}, state) do
    message
      |> List.to_string
      |> String.split(",")
      |> handle_udhcpc(state)
  end

  defp handle_udhcpc(["deconfig", ifname | _rest], state) do
    Logger.info "Deconfigure #{ifname}"
    GenEvent.notify(Nerves.NetworkInterface.event_manager, {:udhcpc, self, :deconfig, %{ifname: ifname}})
    {:noreply, state}
  end
  defp handle_udhcpc(["bound", ifname, ip, broadcast, subnet, router, domain, dns, _message], state) do
    dnslist = String.split(dns, " ")
    Logger.info "Bound #{ifname}: IP=#{ip}, dns=#{inspect dns}"
    GenEvent.notify(Nerves.NetworkInterface.event_manager, {:udhcpc, self, :bound, %{ifname: ifname, ipv4_address: ip, ipv4_broadcast: broadcast, ipv4_subnet_mask: subnet, ipv4_gateway: router, domain: domain, nameservers: dnslist}})
    {:noreply, state}
  end
  defp handle_udhcpc(["renew", ifname, ip, broadcast, subnet, router, domain, dns, _message], state) do
    dnslist = String.split(dns, " ")
    Logger.info "Renew #{ifname}"
    GenEvent.notify(Nerves.NetworkInterface.event_manager, {:udhcpc, self, :renew, %{ifname: ifname, ipv4_address: ip, ipv4_broadcast: broadcast, ipv4_subnet_mask: subnet, ipv4_gateway: router, domain: domain, nameservers: dnslist}})
    {:noreply, state}
  end
  defp handle_udhcpc(["leasefail", ifname, _ip, _broadcast, _subnet, _router, _domain, _dns, message], state) do
    Logger.info "#{ifname}: leasefail #{message}"
    GenEvent.notify(Nerves.NetworkInterface.event_manager, {:udhcpc, self, :leasefail, %{ifname: ifname, message: message}})
    {:noreply, state}
  end
  defp handle_udhcpc(["nak", ifname, _ip, _broadcast, _subnet, _router, _domain, _dns, message], state) do
    Logger.info "#{ifname}: NAK #{message}"
    GenEvent.notify(Nerves.NetworkInterface.event_manager, {:udhcpc, self, :nak, %{ifname: ifname, message: message}})
    {:noreply, state}
  end
  defp handle_udhcpc(something_else, state) do
    msg = List.foldl(something_else, "", &<>/2)
    Logger.info "Got info message: #{msg}"
    {:noreply, state}
  end

  defp hostname() do
    # Turn :sname@host into a hostname
    # Returns "nohost" if Erlang distribution not enabled
    node
      |> to_string
      |> String.split("@")
      |> Enum.at(1)
  end
end
