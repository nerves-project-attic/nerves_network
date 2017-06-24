alias Nerves.Network.Config

defmodule Static do
  def up do
    Nerves.Network.setup "ens38",
      ipv4_address_method: :static,
      ipv4_address: "192.168.1.2",
      ipv4_subnet_mask: "255.255.255.0",
      domain: "test",
      nameservers: ["8.8.8.8", "8.8.4.4"]
  end

  def down do

  end
end

defmodule DHCP do
  def up do
    Nerves.Network.setup "ens38",
      ipv4_address_method: :dhcp
  end

  def down do

  end
end
