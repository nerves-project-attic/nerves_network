defmodule Nerves.Network.IFSupervisor do
  use Supervisor

  @moduledoc false

  def start_link(options \\ []) do
    Supervisor.start_link(__MODULE__, [], options)
  end

  def init([]) do
      {:ok, {{:one_for_one, 10, 3600}, []}}
  end

  def setup(ifname, settings) when is_atom(ifname) do
    setup(to_string(ifname), settings)
  end
  def setup(ifname, settings) do
    pidname = pname(ifname)
    if !Process.whereis(pidname) do
      manager_module = manager(if_type(ifname), settings)
      child = worker(manager_module,
                    [ifname, settings, [name: pidname]],
                    id: pidname)
      Supervisor.start_child(__MODULE__, child)
    else
      {:error, :already_added}
    end
  end

  def teardown(ifname) do
    pidname = pname(ifname)
    if Process.whereis(pidname) do
      Supervisor.terminate_child(__MODULE__, pidname)
      Supervisor.delete_child(__MODULE__, pidname)
    else
      {:error, :not_started}
    end
  end

  def scan(ifname) do
     pidname = pname(ifname)
     if Process.whereis(pidname) do
       GenServer.call(pidname, :scan, 30_000)
     else
       {:error, :not_started}
     end
  end

  defp pname(ifname) do
    String.to_atom("Nerves.Network.Interface." <> ifname)
  end

  # Return the appropriate interface manager based on the interface's type
  # and settings
  defp manager(:wired, settings) do
    case Keyword.get(settings, :ipv4_address_method) do
      :static -> Nerves.Network.StaticManager
      :linklocal -> Nerves.Network.LinkLocalManager
      :dhcp -> Nerves.Network.DHCPManager

      # Default to DHCP if unset; crash if anything else.
      nil -> Nerves.Network.DHCPManager
    end
  end
  defp manager(:wireless, _settings) do
    Nerves.Network.WiFiManager
  end

  # Categorize networks into wired and wireless based on their if names
  defp if_type(<<"eth", _rest::binary>>), do: :wired
  defp if_type(<<"usb", _rest::binary>>), do: :wired
  defp if_type(<<"lo", _rest::binary>>), do: :wired  # Localhost
  defp if_type(<<"wlan", _rest::binary>>), do: :wireless
  defp if_type(<<"ra", _rest::binary>>), do: :wireless  # Ralink

  # systemd predictable names
  defp if_type(<<"en", _rest::binary>>), do: :wired
  defp if_type(<<"sl", _rest::binary>>), do: :wired # SLIP
  defp if_type(<<"wl", _rest::binary>>), do: :wireless
  defp if_type(<<"ww", _rest::binary>>), do: :wired # wwan (not really supported)

  defp if_type(_ifname), do: :wired
end
