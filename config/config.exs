use Mix.Config

key_mgmt = System.get_env("NERVES_NETWORK_KEY_MGMT") || "WPA-PSK"

config :nerves_network, :default,
  wlan0: [
    ssid: System.get_env("NERVES_NETWORK_SSID"),
    psk: System.get_env("NERVES_NETWORK_PSK"),
    key_mgmt: String.to_atom(key_mgmt)
  ],

#:stateful - Address and other-information i.e. DNSes; The flow is being defined by the DHCPv6 server via A, O, M flags sent in Router Advertisements
  #:stateless - only non-address information
  eth0: [
    ipv4_address_method: :dhcp,
    ipv6_dhcp: :stateful
  ]

#The prefixes for the lease and pid file. The file anmes will be appended witht the inetrface's name
#i.e. dhclient6.leases.eth0
config :nerves_network, :dhclient,
  ipv6: [
    lease_file: "/root/dhclient6.leases",
    pid_file:   "/root/dhclient6.pid"
  ]


