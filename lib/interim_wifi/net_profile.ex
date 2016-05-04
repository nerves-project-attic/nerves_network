defmodule Nerves.InterimWiFi.NetProfile do

  defstruct ifname: nil,     # "eth0" or "wlan0", etc.
            type: :ethernet, # :ethernet or :wifi
            ipv4_address_method: :dhcp, # :static, :dhcp, :link_local
            static_ip: %{},  # See NetBasic.set_config. e.g. %{ipv4_address: "1.2.3.4", ipv4_subnet_mask: "255.255.255.0"}
            static_dns: %{}, # {domain: "xyz.com", nameservers: ["8.8.8.8"]}
            wlan: %{}

end
