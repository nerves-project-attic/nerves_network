defmodule Nerves.Network.Types do
  @moduledoc "Types for interacting with Network."

  @typedoc "Ipaddress string."
  @type ip_address :: String.t()

  @typedoc "Interface name string."
  @type ifname :: String.t()

  # Please move this innto Nerves.NetworkInterface.
  @typedoc "Event from Nerves.NetworkInterface"
  @type ifevent :: :ifadded | :ifremoved | :ifmoved | :ifup | :ifdown | :noop

  @typedoc "Atom for the context state machine."
  @type interface_context :: :removed | :retry_add | :down | :up

  @type udhcp_info :: %{ifname: ifname, nameservers: [ip_address], domain: String.t()}

  @type ip_settings :: %{
          optional(:ipv4_address_method) => String.t(),
          optional(:ipv4_address) => String.t(),
          optional(:ipv4_broadcast) => String.t(),
          optional(:ipv4_subnet_mask) => String.t(),
          optional(:ipv4_gateway) => String.t(),
          optional(:domain) => String.t(),
          optional(:nameservers) => String.t()
        }
end
