defmodule Nerves.InterimWiFi.Utils do
  def notify(registry, key, notif, data) do
    Registry.dispatch(registry, key, fn entries ->
      for {pid, _} <- entries, do: send(pid, {registry, notif, data})
    end)
  end
end
