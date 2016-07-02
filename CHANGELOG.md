# Changelog

## v0.0.2

  * Bug fixes
    * Don't crash on invalid wpa_supplicant settings - just wait for the
      caller to fix them and carry on. Crashing turned out to be confusing
      since the error were things like the WPA password was too short.

## v0.0.1

Initial release
