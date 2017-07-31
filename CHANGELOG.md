# Changelog

## v0.3.1
  * Bug Fixes
    * Catch all unspecified context switches and safely return in DHCP_Manager


## v0.3.0
  * Enhancements
    * Replaced Registry with SystemRegistry
    * Allow default configuration to be set in the application config
    * Lengthened the DHCP retry interval to 60 seconds
    * Added Link Local support
    * Pass udhcpc the hostname from :inet.gethostname/0 instead of deriving it from the node name
  * Bug Fixes
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
