defmodule Nerves.InterimWiFi do
  use Application
  require Logger

  def start(_type, _args) do
    import Supervisor.Spec, warn: false

    children = [
      worker(Nerves.InterimWiFi.Resolvconf, ["/tmp/resolv.conf", [name: Nerves.InterimWiFi.Resolvconf]]),
      supervisor(Nerves.InterimWiFi.IFSupervisor, [[name: Nerves.InterimWiFi.IFSupervisor]]),
    ]

    # See http://elixir-lang.org/docs/stable/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :rest_for_one, name: Nerves.InterimWiFi.Supervisor]
    Supervisor.start_link(children, opts)
  end

  @doc """
  Configure the specified interface. Settings contains one or more of the
  following:

    * `:ipv4_address_method` - `:dhcp` or `:static`
    * `:ipv4_address` - e.g., "192.168.1.5" (specify when :ipv4_address_method = :static)
    * `:ipv4_subnet_mask` - e.g., "255.255.255.0" (specify when :ipv4_address_method = :static)
    * `:domain` - e.g., "mycompany.com" (specify when :ipv4_address_method = :static)
    * `:nameservers` - e.g., ["8.8.8.8", "8.8.4.4"] (specify when :ipv4_address_method = :static)
    * `:ssid` - "My WiFi AP" (specify if this is a wireless interface)
    * `:key_mgmt` - e.g., `:"WPA-PSK"` or `:NONE`
    * `:psk` - e.g., "my-secret-wlan-key"

  """
  def setup(ifname, settings \\ []) do
    Logger.debug "#{__MODULE__} setup(#{ifname}, #{inspect settings})"
    Nerves.InterimWiFi.IFSupervisor.setup ifname, settings
  end

  @doc """
  Stop all control if `ifname`
  """
  def teardown(ifname) do
    Logger.debug "#{__MODULE__} teardown(#{ifname})"
    Nerves.InterimWiFi.IFSupervisor.teardown ifname
  end

  @doc """
  Return a map with the current configuration and interface status.
  """
  def status(ifname) do
    Logger.debug "#{__MODULE__} status(#{ifname})"
    Nerves.InterimWiFi.IFSupervisor.status ifname
  end

  @doc """
  If `ifname` is a wireless LAN, scan for access points.
  """
  def scan(ifname) do
    Logger.debug "#{__MODULE__} scan(#{ifname})"
    Nerves.InterimWiFi.IFSupervisor.scan ifname
  end

  @doc """
  Change the regulatory domain for wireless operations. This must be set to the
  two character `alpha2` code for the country where this device is operating.
  See http://git.kernel.org/cgit/linux/kernel/git/sforshee/wireless-regdb.git/tree/db.txt
  for the latest database and the frequencies allowed per country.

  The default is to use the world regulatory domain (00).

  You may also configure the regulatory domain in your app's `config/config.exs`:

      config :nerves_interim_wifi,
        regulatory_domain: "US"
  """
  def set_regulatory_domain(country) do
    Logger.warn "Regulatory domain currently can only be updated on WiFi device addition."
    Application.put_env(:nerves_interim_wifi, :regulatory_domain, country)
  end
end
