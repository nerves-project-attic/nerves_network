# Nerves.Network
[![Build Status](https://travis-ci.org/nerves-project/nerves_network.svg?branch=master)](https://travis-ci.org/nerves-project/nerves_network)
[![Hex version](https://img.shields.io/hexpm/v/nerves_network.svg "Hex version")](https://hex.pm/packages/nerves_network)

Connect to wired and wireless networks on Nerves platforms.

# WiFi Networking

## Installation

You'll first need to set the regulatory domain in your `config.exs` to your ISO
3166-1 alpha-2 country code. In theory this is optional, but you'll get the
world regulatory domain ("00") which is the most restrictive. This may cause
troubles when you try to connect to an access point.

```elixir
config :nerves_network,
  regulatory_domain: "US"
```

## Setup

**Note**
If you are using `nerves_runtime` >= `0.3.0` the kernel module will be auto
loaded by default.

Before WiFi will work, you will need to load any modules for your device if they
aren't loaded already. Here's an example for Raspberry Pi 0 and Raspberry Pi 3

``` elixir
{_, 0} = System.cmd("modprobe", ["brcmfmac"])
```

## Scanning

You can scan by running:

```elixir
iex> {:ok, _pid} = Nerves.Network.setup "wlan0"
iex> Nerves.Network.scan "wlan0"
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

Setup your network connection by running:

```elixir
Nerves.Network.setup "wlan0", ssid: "my_accesspoint_name", key_mgmt: :"WPA-PSK", psk: "secret"
```

If your WiFi network does not use a secret key, specify the `key_mgmt` to be `:NONE`.
Currently, wireless configuration passes almost unaltered to [wpa_supplicant.ex](https://github.com/nerves-project/nerves_wpa_supplicant), so see that
project for more configuration options.

# Wired Networking

Wired networking setup varies in how IP addresses are expected to be assigned.
The following examples show some common setups:

```elixir
# Configure a network that supplies IP addresses via DHCP
Nerves.Network.setup "eth0", ipv4_address_method: :dhcp

# Statically assign an address
Nerves.Network.setup "eth0", ipv4_address_method: :static,
    ipv4_address: "10.0.0.2", ipv4_subnet_mask: "255.255.0.0",
    domain: "mycompany.com", nameservers: ["8.8.8.8", "8.8.4.4"]

# Assign a link-local address
Nerves.Network.setup "usb0", ipv4_address_method: :linklocal
```

## Limitations

Currently, only IPv4 is supported, and IP addresses can only be assigned via
DHCP. The library is incredibly verbose in its logging to help debug issues
on new platforms in prep for a first release. This will change. The library
is mostly interim in its structure. Please consider submitting PRs and helping
make this work reliably across embedded devices.
