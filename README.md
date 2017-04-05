# Nerves.InterimWiFi
[![Build Status](https://travis-ci.org/nerves-project/nerves_interim_wifi.svg?branch=master)](https://travis-ci.org/nerves-project/nerves_interim_wifi)
[![Hex version](https://img.shields.io/hexpm/v/nerves_interim_wifi.svg "Hex version")](https://hex.pm/packages/nerves_interim_wifi)

Connect to WiFi networks on Nerves platforms.

## Installation


1. Add nerves_interim_wifi to your list of dependencies in `mix.exs`:
    ```
    def deps do
      [{:nerves_interim_wifi, "~> 0.2.0"}]
    end
    ```

2. Ensure nerves_interim_wifi is started before your application:
  ```
  def application do
    [applications: [:nerves_interim_wifi]]
  end
  ```

3. Set the regulatory domain in your `config.exs`. This should be set to the
   ISO 3166-1 alpha-2 country code where the device is running. If your device
   ships to more than one country, see `Nerves.InterimWiFi.set_regulatory_domain\1`.
     * if unset, the default regulatory domain is the world domain, "00"
      ```
      config :nerves_interim_wifi,
        regulatory_domain: "US"
      ```

## Setup
Before WiFi will work, you will need to load any modules for your device if they
aren't loaded already. Here's an example for Raspberry Pi 0 and Rasbperry Pi 3
    `{_, 0} = System.cmd("modprobe", ["brcmfmac"])`

## Scanning
You can scan by running:
    `iex> {:ok, _pid} = Nerves.InterimWiFi.setup "wlan0"`
    `iex> Nerves.InterimWiFi.scan "wlan0"`
    ```
    [%{age: 42, beacon_int: 100, bssid: "00:1f:90:db:45:54", capabilities: 1073,
       flags: "[WEP][ESS]", freq: 2462, id: 8,
       ie: "00053153555434010882848b0c1296182403010b07",
       level: -83, noise: 0, qual: 0, ssid: "1SUT4", tsf: 580579066269},
     %{age: 109, beacon_int: 100, bssid: "00:18:39:7a:23:e8", capabilities: 1041,
       flags: "[WEP][ESS]", freq: 2412, id: 5,
       ie: "00076c696e6b737973010882848b962430486c0301",
       level: -86, noise: 0, qual: 0, ssid: "linksys", tsf: 464957892243},
     %{age: 42, beacon_int: 100, bssid: "1c:7e:e5:32:d1:f8", capabilities: 1041,
       flags: "[WPA2-PSK-CCMP][ESS]", freq: 2412, id: 0,
       ie: "000768756e6c657468010882848b960c1218240301",
       level: -43, noise: 0, qual: 0, ssid: "dlink", tsf: 580587711245}]
    ```

## Running

Setup your WiFi connection by running:

    `Nerves.InterimWiFi.setup "wlan0", ssid: "my_accesspoint_name", key_mgmt: :"WPA-PSK", psk: "secret"`

If your WiFi network does not use a secret key, specify the `key_mgmt` to be `:NONE`.
Currently, wireless configuration passes almost unaltered to [wpa_supplicant.ex](https://github.com/nerves-project/nerves_wpa_supplicant), so see that
project for more configuration options.

## Limitations

Currently, only IPv4 is supported, and IP addresses can only be assigned via
DHCP. The library is incredibly verbose in its logging to help debug issues
on new platforms in prep for a first release. This will change. The library
is mostly interim in its structure. Please consider submitting PRs and helping
make this work reliably across embedded devices.
