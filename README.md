# Nerves.InterimWiFi
[![Build Status](https://travis-ci.org/nerves-project/nerves_interim_wifi.svg?branch=master)](https://travis-ci.org/nerves-project/nerves_interim_wifi)
[![Hex version](https://img.shields.io/hexpm/v/nerves_interim_wifi.svg "Hex version")](https://hex.pm/packages/nerves_interim_wifi)

Connect to WiFi networks on Nerves platforms.

## Installation

If [available in Hex](https://hex.pm/docs/publish), the package can be installed as:

  1. Add nerves_interim_wifi to your list of dependencies in `mix.exs`:

        def deps do
          [{:nerves_interim_wifi, "~> 0.0.1"}]
        end

  2. Ensure nerves_interim_wifi is started before your application:

        def application do
          [applications: [:nerves_interim_wifi]]
        end

  3. Set the regulatory domain in your `config.exs`. This should be set to the
     ISO 3166-1 alpha-2 country code where the device is running. If your device
     ships to more than one country, see `Nerves.InterimWifi.set_regulatory_domain\1`.

        # if unset, the default regulatory domain is the world domain, "00"
        config :nerves_interim_wifi,
          regulatory_domain: "US"

## Running

Setup your WiFi connection by running:

    Nerves.InterimWiFi.setup "wlan0", ssid: "my_accesspoint_name", key_mgmt: :"WPA-PSK", psk: "secret"

If your WiFi network does not use a secret key, specify the `key_mgmt` to be `:NONE`.
Currently, wireless configuration passes almost unaltered to [wpa_supplicant.ex](https://github.com/fhunleth/wpa_supplicant.ex), so see that
project for more configuration options.

## Limitations

Currently, only IPv4 is supported, and IP addresses can only be assigned via
DHCP. The library is incredibly verbose in its logging to help debug issues
on new platforms in prep for a first release. This will change. The library
is mostly interim in its structure. Please consider submitting PRs and helping
make this work reliably across embedded devices.
