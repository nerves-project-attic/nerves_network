defmodule Nerves.Network.Utils do
  @moduledoc false
  @scope [:state, :network_interface]

  @doc false
  def log_atomized_iface_error(ifname) when is_atom(ifname) do
    require Logger

    Logger.warn(
      "Support for atom interface names is deprecated. Please consider calling as \"#{ifname}\"."
    )
  end

  def notify(registry, key, notif, data) do
    Registry.dispatch(registry, key, fn entries ->
      for {pid, _} <- entries, do: send(pid, {registry, notif, data})
    end)
  end

  def generate_link_local(mac_address) do
    <<x, y, _rest::bytes>> = :crypto.hash(:md5, mac_address)

    x =
      case x do
        255 -> 254
        0 -> 1
        v -> v
      end

    "169.254.#{x}.#{y}"
  end

  def scope(iface, append \\ []) do
    @scope ++ [iface | append]
  end

  @spec is_hex?(String.t()) :: boolean()
  defp is_hex?(octet) do
    try do
      String.to_integer(octet, 16)
      true
    rescue
      _ -> false
    end
  end

  @spec is_two_digit?(String.t()) :: boolean()
  defp is_two_digit?(octet), do: String.length(octet) == 2


  @spec is_two_digit_octet?(String.t()) :: boolean()
  defp is_two_digit_octet?(octet) do
    is_hex?(octet) and is_two_digit?(octet)
  end

  @doc """
  Returns `true | false`.

  ## Parameters
  - mac: MAC address string ':' seprated i.e. "00:00:00:17:12:79"

  ## Examples

        iex> Nerves.Network.Utils.is_mac_eui_48?("00:00:00:17:12:79")
        true

        iex> "00:00:00:17:12" |> Nerves.Network.Utils.is_mac_eui_48?()
        false

        iex> "00:00:00:17:12:gg" |> Nerves.Network.Utils.is_mac_eui_48?()
        false

        iex> "00:00:00:17:12:79:af" |> Nerves.Network.Utils.is_mac_eui_48?()
        false
  """
  @spec is_mac_eui_48?(String.t()) :: boolean()
  def is_mac_eui_48?(mac) do
    split_mac = String.split(mac, ":")
    if Enum.count(split_mac) == 6 do
      Enum.all?(split_mac, fn octet -> is_two_digit_octet?(octet) end)
    else
      false
    end
  end

  @doc """
  Returns `true | false`.

  ## Parameters
  - mac: MAC address string ':' seprated i.e. "03:14:15:92:65:35:89:79"

  ## Examples

        iex> "03:14:15:92:65:35:89:79" |> Nerves.Network.Utils.is_mac_eui_64?()
        true

        iex> "03:14:15:92:65:35" |> Nerves.Network.Utils.is_mac_eui_64?()
        false

        iex> "00:00:00:17:12:gg" |> Nerves.Network.Utils.is_mac_eui_64?()
        false

        iex> "00:00:00:17:12:79:af" |> Nerves.Network.Utils.is_mac_eui_64?()
        false

        iex> "aa:14:15:92:65:35:89:79" |> Nerves.Network.Utils.is_mac_eui_64?()
        true

        iex> "ag:14:15:92:65:35:89:79" |> Nerves.Network.Utils.is_mac_eui_64?()
        false
  """
  @spec is_mac_eui_64?(String.t()) :: boolean()
  def is_mac_eui_64?(mac) do
    split_mac = String.split(mac, ":")
    if Enum.count(split_mac) == 8 do
      Enum.all?(split_mac, fn octet -> is_two_digit_octet?(octet) end)
    else
      false
    end
  end
end
