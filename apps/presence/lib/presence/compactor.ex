defmodule Presence.Compactor do
  @moduledoc "Compacts per-device presence into per-user status."

  @spec compact(map()) :: map()
  def compact(presence_list) do
    Enum.reduce(presence_list, %{}, fn {user_id, %{metas: metas}}, acc ->
      status =
        if Enum.any?(metas, &(&1.status == :online)), do: :online, else: :away

      devices = Enum.map(metas, & &1.device_id)

      Map.put(acc, user_id, %{status: status, devices: devices})
    end)
  end
end
