defmodule Nerves.Network do
  require Logger
  alias Nerves.Network.Types

  @moduledoc """
  The Nerves.Network application handles the low level details of connecting
  to networks. To quickly get started, create a new Nerves project and add
  the following line someplace early on in your program:

      Nerves.Network.setup "wlan0", ssid: "myssid", key_mgmt: :"WPA-PSK", psk: "secretsecret"

  When you boot your Nerves image, Nerves.Network monitors for an interface
  called "wlan0" to be created. This occurs when you plug in a USB WiFi dongle.
  If you plug in more than one WiFi dongle, each one will be given a name like
  "wlan1", etc. Those may be setup as well.

  When not connected, Nerves.Network continually scans
  for the desired access point. Once found, it associates and runs DHCP to
  acquire an IP address.
  """

  @typedoc "Settings to `setup/2`"
  @type setup_setting ::
          {:ipv4_address_method, :dhcp | :static | :linklocal}
          | {:ipv4_address, Types.ip_address()}
          | {:ipv4_subnet_mask, Types.ip_address()}
          | {:domain, String.t()}
          | {:nameservers, [Types.ip_address()]}
          | {:ssid, String.t()}
          | {:key_mgmt, :"WPA-PSK" | :NONE}
          | {:psk, String.t()}

  @typedoc "Keyword List settings to `setup/2`"
  @type setup_settings :: [setup_setting]

  @doc """
  Configure the specified interface. Settings contains one or more of the
  following:

    * `:ipv4_address_method` - `:dhcp`, `:static`, or `:linklocal`
    * `:ipv4_address` - e.g., "192.168.1.5" (specify when :ipv4_address_method = :static)
    * `:ipv4_subnet_mask` - e.g., "255.255.255.0" (specify when :ipv4_address_method = :static)
    * `:domain` - e.g., "mycompany.com" (specify when :ipv4_address_method = :static)
    * `:nameservers` - e.g., ["8.8.8.8", "8.8.4.4"] (specify when :ipv4_address_method = :static)
    * `:ssid` - "My WiFi AP" (specify if this is a wireless interface)
    * `:key_mgmt` - e.g., `:"WPA-PSK"` or `:NONE`
    * `:psk` - e.g., "my-secret-wlan-key"

  See [the type info](Nerves.Network.html#t:setup_settings/0) for more info.

  Returns `:ok` or `{:error, reason}` if there is an error.
  currently the only error that gets checked is if the interface doesn't exist.

  ## Waiting for an interface to come up
  Nerves.Network versions before `0.3.7` would simply return `:ok` on _any_ interface even if it
  did not exist.
  This means the user will now have to monitor their own interface and wait for
  it to come up.

  ```
  def wait_for_interface_up(interface) do
    unless iface in Nerves.NetworkInterface.interfaces() do
      wait_for_interface_up(interface)
    end
    :ok
  end
  ```
  """
  @spec setup(Types.ifname(), setup_settings) :: :ok | {:error, term}
  def setup(ifname, settings \\ []) do
    if ifname in Nerves.NetworkInterface.interfaces() do
      Logger.debug("#{__MODULE__} setup(#{ifname}, #{inspect(settings)})")
      {:ok, {_new, _old}} = Nerves.Network.Config.put(ifname, settings)
      :ok
    else
      {:error, :no_interface}
    end
  end

  @doc """
  Stop all control of `ifname`
  """
  @spec teardown(Types.ifname()) :: :ok
  def teardown(ifname) do
    Logger.debug("#{__MODULE__} teardown(#{ifname})")
    {:ok, {_new, _old}} = Nerves.Network.Config.drop(ifname)
    :ok
  end

  @doc """
  Convenience function for returning the current status of a network interface
  from SystemRegistry.
  """
  @spec status(Types.ifname()) :: Nerves.NetworkInterface.Worker.status() | nil
  def status(ifname) do
    SystemRegistry.match(:_)
    |> get_in([:state, :network_interface, ifname])
  end

  @doc """
  If `ifname` is a wireless LAN, scan for access points.
  """
  @spec scan(Types.ifname()) :: [String.t()] | {:error, any}
  def scan(ifname) do
    Nerves.Network.IFSupervisor.scan(ifname)
  end

  @doc """
  Change the regulatory domain for wireless operations. This must be set to the
  two character `alpha2` code for the country where this device is operating.
  See [the kernel database](http://git.kernel.org/cgit/linux/kernel/git/sforshee/wireless-regdb.git/tree/db.txt)
  for the latest database and the frequencies allowed per country.

  The default is to use the world regulatory domain (00).

  You may also configure the regulatory domain in your app's `config/config.exs`:

      config :nerves_network,
        regulatory_domain: "US"
  """
  @spec set_regulatory_domain(String.t()) :: :ok
  def set_regulatory_domain(country) do
    Logger.warn("Regulatory domain currently can only be updated on WiFi device addition.")
    Application.put_env(:nerves_network, :regulatory_domain, country)
  end
end
