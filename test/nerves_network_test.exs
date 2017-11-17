defmodule Nerves.NetworkTest do
  use ExUnit.Case, async: false
  doctest Nerves.Network

  test "default network interface is not removed when we teardown" do
    assert Map.has_key?(:sys.get_state(process.whereis(Nerves.Network.Config)), "eth0")

    Nerves.Network.teardown("eth0")
    assert Map.has_key?(:sys.get_state(process.whereis(Nerves.Network.Config)), "eth0")
  end

  test "non-default network interface is removed when we teardown" do
    Nerves.Network.setup("non-default")
    assert Map.has_key?(:sys.get_state(process.whereis(Nerves.Network.Config)), "non-default")

    Nerves.Network.teardown("non-default")
    refute Map.has_key?(:sys.get_state(process.whereis(Nerves.Network.Config)), "non-default")
  end
end
