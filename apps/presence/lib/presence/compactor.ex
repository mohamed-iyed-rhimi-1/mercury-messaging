defmodule Presence.Compactor do
  @moduledoc "Compacts per-device presence into per-user status."

  @spec compact(map()) :: map()
  def compact(presence_list) do
    Enum.reduce(presence_list, %{}, fn
      {user_id, %{metas: metas}}, acc when is_list(metas) ->
        status =
          if Enum.any?(metas, &(Map.get(&1, :status) == :online)), do: :online, else: :away

        devices = Enum.map(metas, &Map.get(&1, :device_id, "unknown"))

        Map.put(acc, user_id, %{status: status, devices: devices})

      {_user_id, _malformed}, acc ->
        acc
    end)
  end
end
