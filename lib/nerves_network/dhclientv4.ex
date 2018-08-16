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

  @renew 1
  @release 2
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
    Logger.debug("#{__MODULE__}: Dhclientv4 starting for args: #{inspect(args)}")
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
    Logger.debug("Dhclientv4.stop ipid: #{inspect(pid)}")
    GenServer.stop(pid)
  end

  defp append_ifname(input_str, ifname) do
    input_str <> "." <> ifname
  end

  defp runtime_lease_file(ifname, runtime) do
    if Keyword.has_key?(runtime, :lease_file) do
      ["-lf", runtime_lease_file_path(ifname, runtime)]
    else
      []
    end
  end

  defp runtime_lease_file_path(ifname, runtime) do
    Keyword.get(runtime, :lease_file) |> append_ifname(ifname)
  end

  defp runtime_pid_file(ifname, runtime) do
    if Keyword.has_key?(runtime, :pid_file) do
      ["-pf", Keyword.get(runtime, :pid_file) |> append_ifname(ifname)]
    else
      []
    end
  end

  # Parsing config.exs entry of the following format: [dhclient: [lease_file: "/var/lib/dhclient4.leases", pid_file: "/var//run/dhclient4.pid"]]
  defp dhclient_runtime(ifname) do
    runtime = runtime()
    Logger.debug("#{__MODULE__}: runtime options = #{inspect(runtime)}")
    runtime_lease_file(ifname, runtime) ++ runtime_pid_file(ifname, runtime)
  end

  defp runtime() do
    [ipv4: runtime] = Application.get_env(:nerves_network, :dhclientv4, [])
    runtime
  end

  def init(args) do
    {ifname, mode} = args

    Logger.info(
      "#{__MODULE__}: Starting Dhclientv4 wrapper for ifname: #{inspect(ifname)} mode: #{
        inspect(mode)
      }"
    )

    priv_path = :code.priv_dir(:nerves_network)
    port_path = "#{priv_path}/dhclientv4_wrapper"

    # This is a workaround to handle the case where we change networks
    if Application.get_env(:nerves_network, :flush_lease_db) do
      runtime_lease_file_path(ifname, runtime())
      |> to_string()
      |> File.rm()
    end

    args =
      [
        "dhclient",
        # ipv4
        "-4",
        # The script to be invoked at the lease time
        "-sf",
        port_path,
        "-v",
        "-d"
      ] ++ dhclient_runtime(ifname) ++ [ifname]

    port =
      Port.open(
        {:spawn_executable, port_path},
        [{:args, args}, :exit_status, :stderr_to_stdout, {:line, 256}]
      )

    Logger.info("#{__MODULE__}: Dhclientv4 port: #{inspect(port)}; args: #{inspect(args)}")

    {:ok, %{ifname: ifname, port: port, running: true}}
  end

  def terminate(_reason, state = %{running: true}) do
    # Send the command to our wrapper to shut everything down.
    Logger.debug("#{__MODULE__}: terminate...")
    Port.command(state.port, <<@terminate>>)
    Port.close(state.port)
    :ok
  end

  def terminate(_reason, _state) do
    :ok
  end

  def handle_call(:renew, _from, state) do
    # If we send a byte with the value 1 to the wrapper, it will turn it into
    # a SIGUSR1 for dhclient so that it renews the IP address.
    Port.command(state.port, <<@renew>>)
    {:reply, :ok, state}
  end

  def handle_call(:release, _from, state) do
    Port.command(state.port, <<@release>>)
    {:reply, :ok, state}
  end

  #  Nerves.Network.Dhclientv4.handle_info({#Port<0.6423>, {:exit_status, 0}}, %{ifname: "eth1", port: #Port<0.6423>})
  def handle_info({_pid, {:exit_status, exit_status}}, state) do
    Logger.error(
      "dhclientv4 exited: exit_status = #{inspect(exit_status)}, state = #{inspect(state)}"
    )

    {:stop, :exit, %{state | running: false}}
  end

  def handle_info({_, {:data, {:eol, message}}}, state) do
    handle(message, state)
  end

  # def handle(message, state) do
  #   Logger.debug "This is message: #{inspect message}"
  #   message_s = List.to_string(message)
  #   Logger.debug "This is message_s: #{inspect message_s}"
  #   message_l = String.split(message_s, ",")
  #   Logger.debug "This is message_l: #{inspect message_l}"
  #   handle_dhclient(message_l, state)
  # end

  def handle(message, state) do
    message
    |> List.to_string()
    |> String.split(",")
    |> handle_dhclient(state)
  end

  @typedoc "State of the GenServer."
  @type state :: %{ifname: Types.ifname(), port: port}

  @typedoc "Message from the dhclientv4 port."
  # we can do better.
  @type dhclientv4_wrapper_event :: [...]

  @typedoc "Event from the dhclientv4 server to be sent via SystemRegistry."
  @type event :: :deconfig | :bound | :renew | :leasefail | :reboot | :nak | :ifdown

  @spec handle_dhclient(dhclientv4_wrapper_event, state) :: {:noreply, state}
  defp handle_dhclient(["deconfig", ifname | _rest], state) do
    Logger.debug("dhclientv4: deconfigure #{ifname}")

    Utils.notify(Nerves.Dhclientv4, state.ifname, :deconfig, %{ifname: ifname})
    {:noreply, state}
  end

  defp handle_dhclient([reason, _ifname, _ip, _broadcast, _subnet, _router, _domain, _dns], state)
       when reason in ["MEDIUM", "ARPCHECK", "ARPSEND", "TIMEOUT"] do
    Logger.debug(
      "dhclientv4: Received reason '#{reason}'. Not performing any update to network interface."
    )

    {:noreply, state}
  end

  defp handle_dhclient(["BOUND", ifname, ip, broadcast, subnet, router, domain, dns], state) do
    dnslist = String.split(dns, " ")

    Logger.debug(
      "dhclientv4: Received reason 'BOUND'. #{ifname}: IP=#{ip}, dns=#{inspect(dns)} router=#{
        inspect(router)
      }"
    )

    Utils.notify(Nerves.Dhclientv4, state.ifname, :bound, %{
      ifname: ifname,
      ipv4_address: ip,
      ipv4_broadcast: broadcast,
      ipv4_subnet_mask: subnet,
      ipv4_gateway: router,
      domain: domain,
      nameservers: dnslist
    })

    {:noreply, state}
  end

  defp handle_dhclient(["REBOOT", ifname, ip, broadcast, subnet, router, domain, dns], state) do
    dnslist = String.split(dns, " ")

    Logger.debug(
      "dhclientv4: Received reason 'REBOOT'. #{ifname}: IP=#{ip}, dns=#{inspect(dns)} router=#{
        inspect(router)
      }"
    )

    Utils.notify(Nerves.Dhclientv4, state.ifname, :reboot, %{
      ifname: ifname,
      ipv4_address: ip,
      ipv4_broadcast: broadcast,
      ipv4_subnet_mask: subnet,
      ipv4_gateway: router,
      domain: domain,
      nameservers: dnslist
    })

    {:noreply, state}
  end

  defp handle_dhclient(["RENEW", ifname, ip, broadcast, subnet, router, domain, dns], state) do
    dnslist = String.split(dns, " ")

    Logger.debug(
      "dhclientv4: Received reason 'RENEW'. #{ifname}: IP=#{ip}, dns=#{inspect(dns)} router=#{
        inspect(router)
      }"
    )

    Utils.notify(Nerves.Dhclientv4, state.ifname, :renew, %{
      ifname: ifname,
      ipv4_address: ip,
      ipv4_broadcast: broadcast,
      ipv4_subnet_mask: subnet,
      ipv4_gateway: router,
      domain: domain,
      nameservers: dnslist
    })

    {:noreply, state}
  end

  defp handle_dhclient(["REBIND", ifname, ip, broadcast, subnet, router, domain, dns], state) do
    dnslist = String.split(dns, " ")

    Logger.debug(
      "dhclientv4: Received reason 'REBIND'. #{ifname}: IP=#{ip}, dns=#{inspect(dns)} router=#{
        inspect(router)
      }"
    )

    Utils.notify(Nerves.Dhclientv4, state.ifname, :rebind, %{
      ifname: ifname,
      ipv4_address: ip,
      ipv4_broadcast: broadcast,
      ipv4_subnet_mask: subnet,
      ipv4_gateway: router,
      domain: domain,
      nameservers: dnslist
    })

    {:noreply, state}
  end

  defp handle_dhclient(
         ["PREINIT", ifname, _ip, _broadcast, _subnet, _router, _domain, _dns],
         state
       ) do
    Logger.debug("dhclientv4:  Received reason 'PREINIT'. Bringing #{ifname} up.")
    Utils.notify(Nerves.Dhclientv4, state.ifname, :ifup, %{ifname: ifname})
    {:noreply, state}
  end

  defp handle_dhclient([reason, ifname, _ip, _broadcast, _subnet, _router, _domain, _dns], state)
       when reason in ["EXPIRE", "FAIL", "RELEASE", "STOP"] do
    Logger.debug("dhclientv4: Received reason '#{reason}'. Bringing #{ifname} down.")
    Utils.notify(Nerves.Dhclientv4, state.ifname, :ifdown, %{ifname: ifname})
    {:noreply, state}
  end

  # Handling informational debug prints from the dhclient
  defp handle_dhclient([message], state) do
    Logger.debug(
      "#{__MODULE__} handle_dhclient args = #{inspect(message)} state = #{inspect(state)}"
    )

    {:noreply, state}
  end

  defp handle_dhclient(something_else, state) do
    msg = List.foldl(something_else, "", &<>/2)
    Logger.debug("dhclient: ignoring unhandled message: #{msg}")
    {:noreply, state}
  end
end
