# Changelog

## v0.5.4

* Bug fixes
  * Ensure config coming from system_registry is passed to the interface as
    a keyword list

## v0.5.3

* Bug fixes
  * Fix unhandled state change from `removed` -> `deconfigure`

## v0.5.2

* Bug fixes
  * Fix race condition when setting `default` config from application env

## v0.5.1

* Bug fixes
  * Calling `setup` from different processes will work properly now
  * Fix runtime exception with some combinations of settings

## v0.5.0

* Enhancements
  * Support individual IP settings for each WiFi network priority.
* Bug fixes
  * Disconnecting from WiFi will unset IP settings.
    * [#90](https://github.com/nerves-project/nerves_network/issues/90)
    * [#35](https://github.com/nerves-project/nerves_network/issues/35)
    * [#26](https://github.com/nerves-project/nerves_network/issues/26)
    * [#22](https://github.com/nerves-project/nerves_network/issues/22)
  * Calling `setup` from IEx will now set a new Network
    * [#92](https://github.com/nerves-project/nerves_network/issues/92)

## v0.4.0

* Enhancements
  * Removed WiFi credentials from Logger
  * Support configuration of multiple networks.
    See [#72](https://github.com/nerves-project/nerves_network/issues/72)

## v0.3.7
  * Add typespecs for all the moving parts.
    * Small refactors relating to this.
  * Run Elixir code formatter.
      * CI will now fail if the formatter fails.
  * Add deprecation warning if users try to setup a network interface with
    an atomized interface instead of a bitstring.
    * [#17](https://github.com/nerves-project/nerves_network/issues/17)
    * [#29](https://github.com/nerves-project/nerves_network/issues/29)
    * [#41](https://github.com/nerves-project/nerves_network/issues/41)
  * Changed `setup/2` API to not return delta from SystemRegistry
    * [#23](https://github.com/nerves-project/nerves_network/issues/23)
  * Changed `teardown/1` API similarly.
  * Added docs for general usage.
    * [#21](https://github.com/nerves-project/nerves_network/issues/21)
    * [#19](https://github.com/nerves-project/nerves_network/issues/19)

## v0.3.6
  * Bug fixes
    * Fix wired DHCP manager, not claiming ip address.

## v0.3.5

  * Enhancements
    * Fix reporting of unhandled DHCP events.

## v0.3.4

  * Enhancements
    * Make `:dhcp` the default `ipv4_address_method` when unspecified.
    * Return interface status from SystemRegistry instead of querying
      `nerves_network_interface`. This ensures that all fields are returned.
    * Various documentation improvements

## v0.3.3

  * Enhancements
    * Fix deprecation warnings for Elixir 1.5

## v0.3.2

  * Enhancements
    * Support compilation on OSX. It won't work, but it's good enough for
      generating docs and pushing to hex.

## v0.3.1

This is the initial nerves_network release after the nerves_interim_wifi rename.

  * Bug fixes
    * Catch all unspecified context switches and safely return in DHCP_Manager

## v0.3.0

  * Enhancements
    * Replaced Registry with SystemRegistry
    * Allow default configuration to be set in the application config
    * Lengthened the DHCP retry interval to 60 seconds
    * Added Link Local support
    * Pass udhcpc the hostname from :inet.gethostname/0 instead of deriving it from the node name

  * Bug fixes
    * Updated DHCP state machine to handle edge cases causing a crash.
    * Fixed issue with udhcpc producing zombies

## v0.2.1

* Bug fixes
  * Bumped versions for dependencies

## v0.2.0

* Enhancements
  * Replaced GenEvent with Registry

## v0.1.1

  * Bug fixes
    * Handle ifadded in down state
    * Clean up warnings for Elixir 1.4

## v0.1.0

  * Bug fixes
    * Handle strange latent ifdown

## v0.0.2

  * Bug fixes
    * Don't crash on invalid wpa_supplicant settings - just wait for the
      caller to fix them and carry on. Crashing turned out to be confusing
      since the error were things like the WPA password was too short.

## v0.0.1

Initial release
