defmodule Nerves.Network.IFSupervisor do
  use Supervisor
  alias Nerves.Network.Types
  import Nerves.Network.Utils, only: [log_atomized_iface_error: 1]

  @moduledoc false

  @spec start_link(GenServer.options()) :: GenServer.on_start()
  def start_link(options \\ []) do
    Supervisor.start_link(__MODULE__, [], options)
  end

  def init([]) do
    {:ok, {{:one_for_one, 10, 3600}, []}}
  end

  @spec setup(Types.ifname() | atom, Nerves.Network.setup_settings()) ::
          Supervisor.on_start_child()
  def setup(ifname, settings) when is_atom(ifname) do
    log_atomized_iface_error(ifname)
    setup(to_string(ifname), settings)
  end

  def setup(ifname, settings)
      when is_atom(ifname)
      when is_list(settings) do
    pidname = pname(ifname)
    manager_module = manager(if_type(ifname), settings)
    child = worker(manager_module, [ifname, settings, [name: pidname]], id: pidname)
    Supervisor.start_child(__MODULE__, child)
  end

  @spec teardown(Types.ifname()) ::
          :ok | {:error, any} | :not_found | :simple_one_for_one | :running | :restarting
  def teardown(ifname) do
    pidname = pname(ifname)

    if pid = Process.whereis(pidname) do
      Process.alive?(pid) && GenServer.call(pidname, :teardown, 30_000)
    end

    case Supervisor.terminate_child(__MODULE__, pidname) do
      :ok -> Supervisor.delete_child(__MODULE__, pidname)
      er -> er
    end
  end

  # Support atom interface names to avoid breaking some existing
  # code. This is a deprecated use of the API.
  @spec scan(Types.ifname() | atom) :: [String.t()] | {:error, any}
  def scan(ifname) when is_atom(ifname) do
    log_atomized_iface_error(ifname)
    scan(to_string(ifname))
  end

  def scan(ifname) when is_binary(ifname) do
    with pid when is_pid(pid) <- Process.whereis(pname(ifname)),
         :wireless <- if_type(ifname) do
      GenServer.call(pid, :scan, 30_000)
    else
      # If there is no pid.
      nil ->
        {:error, :not_started}

      # if the interface was wired.
      :wired ->
        {:error, :not_wireless}
    end
  end

  @spec pname(Types.ifname()) :: atom
  defp pname(ifname) do
    String.to_atom("Nerves.Network.Interface." <> ifname)
  end

  # Return the appropriate interface manager based on the interface's type
  # and settings
  @spec manager(:wired | :wireless, Nerves.Network.setup_settings()) ::
          Nerves.Network.StaticManager
          | Nerves.Network.LinkLocalManager
          | Nerves.Network.DHCPManager
          | Nerves.Network.WiFiManager
  defp manager(:wired, settings) do
    case Keyword.get(settings, :ipv4_address_method) do
      :static ->
        Nerves.Network.StaticManager

      :linklocal ->
        Nerves.Network.LinkLocalManager

      :dhcp ->
        Nerves.Network.DHCPManager

      # Default to DHCP if unset; crash if anything else.
      nil ->
        Nerves.Network.DHCPManager
    end
  end

  defp manager(:wireless, _settings) do
    Nerves.Network.WiFiManager
  end

  @spec if_type(Types.ifname()) :: :wired | :wireless
  # Categorize networks into wired and wireless based on their if names
  defp if_type(<<"eth", _rest::binary>>), do: :wired
  defp if_type(<<"usb", _rest::binary>>), do: :wired
  # Localhost
  defp if_type(<<"lo", _rest::binary>>), do: :wired
  defp if_type(<<"wlan", _rest::binary>>), do: :wireless
  # Ralink
  defp if_type(<<"ra", _rest::binary>>), do: :wireless

  # systemd predictable names
  defp if_type(<<"en", _rest::binary>>), do: :wired
  # SLIP
  defp if_type(<<"sl", _rest::binary>>), do: :wired
  defp if_type(<<"wl", _rest::binary>>), do: :wireless
  # wwan (not really supported)
  defp if_type(<<"ww", _rest::binary>>), do: :wired

  defp if_type(_ifname), do: :wired
end
