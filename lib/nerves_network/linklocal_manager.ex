defmodule Nerves.Network.LinkLocalManager do
  use GenServer
  require Logger
  import Nerves.Network.Utils

  @moduledoc false

  # The current state machine state is called "context" to avoid confusion between server
  # state and state machine state.
  defstruct context: :removed,
            ifname: nil,
            settings: nil

  def start_link(ifname, settings, opts \\ []) do
    GenServer.start_link(__MODULE__, {ifname, settings}, opts)
  end

  def init({ifname, settings}) do
    # Register for nerves_network_interface and udhcpc events
    {:ok, _} = Registry.register(Nerves.NetworkInterface, ifname, [])

    state = %Nerves.Network.LinkLocalManager{settings: settings, ifname: ifname}
    # If the interface currently exists send ourselves a message that it
    # was added to get things going.
    current_interfaces = Nerves.NetworkInterface.interfaces
    state =
      if Enum.member?(current_interfaces, ifname) do
        consume(state.context, :ifadded, state)
      else
        state
      end

    {:ok, state}
  end

  def handle_event({Nerves.NetworkInterface, :ifadded, %{ifname: ifname}}) do
    Logger.debug "LinkLocalManager.EventHandler(#{ifname}) ifadded"
    :ifadded
  end
  # :ifmoved occurs on systems that assign stable names to removable
  # interfaces. I.e. the interface is added under the dynamically chosen
  # name and then quickly renamed to something that is stable across boots.
  def handle_event({Nerves.NetworkInterface, :ifmoved, %{ifname: ifname}}) do
    Logger.debug "LinkLocalManager.EventHandler(#{ifname}) ifadded (moved)"
    :ifadded
  end
  def handle_event({Nerves.NetworkInterface, :ifremoved, %{ifname: ifname}}) do
    Logger.debug "LinkLocalManager.EventHandler(#{ifname}) ifremoved"
    :ifremoved
  end

  # Filter out ifup and ifdown events
  # :is_up reports whether the interface is enabled or disabled (like by the wifi kill switch)
  # :is_lower_up reports whether the interface as associated with an AP
  def handle_event({Nerves.NetworkInterface, :ifchanged, %{ifname: ifname, is_lower_up: true}}) do
    Logger.debug "LinkLocalManager.EventHandler(#{ifname}) ifup"
    :ifup
  end
  def handle_event({Nerves.NetworkInterface, :ifchanged, %{ifname: ifname, is_lower_up: false}}) do
    Logger.debug "LinkLocalManager.EventHandler(#{ifname}) ifdown"
    :ifdown
  end

  def handle_event({Nerves.NetworkInterface, event, %{ifname: ifname}}) do
    Logger.debug "LinkLocalManager.EventHandler(#{ifname}): ignoring event: #{inspect event}"
    :noop
  end

  def handle_info({Nerves.NetworkInterface, _, ifstate} = event, %{ifname: ifname} = s) do
    event = handle_event(event)
    scope(ifname) |> SystemRegistry.update(ifstate)
    s = consume(s.context, event, s)
    Logger.debug "LinkLocalManager(#{s.ifname}, #{s.context}) got event #{inspect event}"
    {:noreply, s}
  end

  def handle_info(event, s) do
    Logger.debug "LinkLocalManager.EventHandler(#{s.ifname}): ignoring event: #{inspect event}"
    {:noreply, s}
  end

  ## State machine implementation
  defp goto_context(state, newcontext) do
    %Nerves.Network.LinkLocalManager{state | context: newcontext}
  end

  defp consume(_, :noop, state), do: state
  ## Context: :removed
  defp consume(:removed, :ifadded, state) do
    case Nerves.NetworkInterface.ifup(state.ifname) do
      :ok ->
        {:ok, status} = Nerves.NetworkInterface.status(state.ifname)
        notify(Nerves.NetworkInterface, state.ifname, :ifchanged, status)

        goto_context(state, :down)
      {:error, _} ->
        # The interface isn't quite up yet. Retry
        Process.send_after self(), :retry_ifadded, 250
        goto_context(state, :retry_add)
    end
  end
  defp consume(:removed, :retry_ifadded, state), do: state
  defp consume(:removed, :ifdown, state), do: state

  ## Context: :retry_add
  defp consume(:retry_add, :ifremoved, state) do
    goto_context(state, :removed)
  end
  defp consume(:retry_add, :retry_ifadded, state) do
    {:ok, status} = Nerves.NetworkInterface.status(state.ifname)
    notify(Nerves.NetworkInterface, state.ifname, :ifchanged, status)

    goto_context(state, :down)
  end

  ## Context: :down
  defp consume(:down, :ifadded, state), do: state
  defp consume(:down, :ifup, state) do
    state
      |> start_link_local
      |> goto_context(:up)
  end
  defp consume(:down, :ifdown, state), do: state
  defp consume(:down, :ifremoved, state) do
    goto_context(state, :removed)
  end

  ## Context: :up
  defp consume(:up, :ifup, state), do: state
  defp consume(:up, :ifdown, state) do
    goto_context(state, :down)
  end

  defp start_link_local(state) do
    {:ok, ifsettings} = Nerves.NetworkInterface.status(state.ifname)
    ip = generate_link_local(ifsettings.mac_address)
    :ok = Nerves.NetworkInterface.setup(state.ifname, [ipv4_address: ip])
    state
  end
end
