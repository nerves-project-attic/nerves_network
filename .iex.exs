alias Nerves.InterimWiFi.Config

defmodule W do
  alias Nerves.InterimWiFi.Config
  def put do
    Config.put "wlx0013efd02505", %{ssid: "The Internets", psk: "nothingworkshere", key_mgmt: :"WPA-PSK"}
  end

  def drop do
    Config.drop "wlx0013efd02505"
  end
end
