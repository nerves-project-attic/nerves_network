# Connecting to a Hidden Wireless Network
Connecting to a hidden network is no different than connecting to a
normal broadcasting network, but it has some caveats.

```elixir
  interface = "wlan0"
  :ok = Network.setup(interface, [ssid: "hidden_ssid", psk: "super_secret", key_mgmt: "WPA-PSK"])
  {:ok, _} = Registry.register(Nerves.Udhcpc, interface, [])
  {:ok, _} = Registry.register(Nerves.WpaSupplicant, interface, [])
  :ok = receive do
    {Nerves.WpaSupplicant, :"CTRL-EVENT-NETWORK-NOT-FOUND", _} -> {:error, "network not found"}
    {Nerves.Udhcpc, :bound, %{ifname: ^interface}} -> :ok
  end
```

The above will almost always fail, because to connect to a hidden network,
the underlying client (`wpa_supplicant`) has to wait for a broadcast beacon. So
unless the `setup/2` call happened at the perfect time, you will likely hit the
`:"CTRL-EVENT-NETWORK-NOT-FOUND"` message. 
