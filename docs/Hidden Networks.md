# Connecting to a Hidden Wireless Network
Connecting to a hidden network is no different that connecting to a
normal broadcasting network, but it has some caveats.

```elixir
  :ok = Network.setup("wlan0", [ssid: "hidden_ssid", psk: "super_secret", key_mgmt: "WPA-PSK"])
  {:ok, _} = Elixir.Registry.register(Nerves.Udhcpc, interface, [])
  {:ok, _} = Elixir.Registry.register(Nerves.WpaSupplicant, interface, [])
  :ok = receive do
    {Nerves.WpaSupplicant, :"CTRL-EVENT-NETWORK-NOT-FOUND", _} -> {:error, "network not found"}
    {Nerves.Udhcpc, :bound, %{ifname: "wlan0"}} -> :ok
  end
```

The above will almost always fail, because to connect to a hidden network,
the underlying client (`wpa_supplicant`) has to wait for a broadcast beacon. So
unless the `setup/2` call happened at the perfect time, you will likely hit the
`:"CTRL-EVENT-NETWORK-NOT-FOUND"` message. 
