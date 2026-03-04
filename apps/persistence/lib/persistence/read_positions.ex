defmodule Persistence.ReadPositions do
  @moduledoc "Read position tracking — GCounter (max) semantics, never goes backward."
  require Logger

  @xandra_timeout 5_000

  @spec update(binary(), binary(), binary(), binary()) :: :ok | {:error, term()}
  def update(tenant_id, user_id, channel_id, message_id) do
    case get(tenant_id, user_id, channel_id) do
      # UUIDv7 message IDs are byte-sortable, so >= is correct for the GCounter check
      {:ok, current} when current >= message_id ->
        :ok

      _ ->
        values = [
          {"blob", tenant_id},
          {"blob", user_id},
          {"blob", channel_id},
          {"blob", message_id}
        ]

        case Xandra.Cluster.execute(
               Persistence.Scylla,
               """
               INSERT INTO mercury.read_positions
                 (tenant_id, user_id, channel_id, last_read_message_id, updated_at)
               VALUES (?, ?, ?, ?, toTimestamp(now()))
               """,
               values,
               timeout: @xandra_timeout
             ) do
          {:ok, _} -> :ok
          {:error, _} = err -> err
        end
    end
  end

  @spec get(binary(), binary(), binary()) :: {:ok, binary()} | {:error, :not_found}
  def get(tenant_id, user_id, channel_id) do
    values = [
      {"blob", tenant_id},
      {"blob", user_id},
      {"blob", channel_id}
    ]

    case Xandra.Cluster.execute(
           Persistence.Scylla,
           """
           SELECT last_read_message_id FROM mercury.read_positions
           WHERE tenant_id = ? AND user_id = ? AND channel_id = ?
           """,
           values,
           timeout: @xandra_timeout
         ) do
      {:ok, page} ->
        case Enum.to_list(page) do
          [%{"last_read_message_id" => mid}] when not is_nil(mid) -> {:ok, mid}
          _ -> {:error, :not_found}
        end

      _ ->
        {:error, :not_found}
    end
  end

  @spec get_bulk(binary(), binary(), [binary()]) :: %{binary() => binary()}
  def get_bulk(_tenant_id, _user_id, []), do: %{}

  def get_bulk(tenant_id, user_id, channel_ids) do
    channel_ids
    |> Task.async_stream(
      fn cid ->
        case get(tenant_id, user_id, cid) do
          {:ok, mid} -> {cid, mid}
          {:error, :not_found} -> nil
        end
      end,
      max_concurrency: 10,
      timeout: 5_000
    )
    |> Enum.reduce(%{}, fn
      {:ok, {cid, mid}}, acc -> Map.put(acc, cid, mid)
      _, acc -> acc
    end)
  end
end
