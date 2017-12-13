# Changelog

## v0.3.6
  * Bug Fixes
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

  * Bug Fixes
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

* Bug Fixes
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
