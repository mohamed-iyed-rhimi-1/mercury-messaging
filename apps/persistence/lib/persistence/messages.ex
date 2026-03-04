defmodule Persistence.Messages do
  @moduledoc "ScyllaDB message storage — write and paginated read."
  require Logger

  @xandra_timeout 5_000

  @insert_cql """
  INSERT INTO mercury.messages
    (tenant_id, channel_id, bucket_id, message_id, sender_id,
     encrypted_content, content_type, reply_to, created_at, server_received_at)
  VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
  """

  @select_cql """
  SELECT message_id, sender_id, encrypted_content, content_type,
         reply_to, created_at, server_received_at
  FROM mercury.messages
  WHERE tenant_id = ? AND channel_id = ? AND bucket_id = ?
  ORDER BY message_id DESC
  LIMIT ?
  """

  @type message :: %{
          message_id: binary(),
          sender_id: binary(),
          encrypted_content: binary(),
          content_type: integer(),
          reply_to: binary() | nil,
          created_at: integer()
        }

  @spec write(binary(), binary(), integer(), message()) :: :ok | {:error, term()}
  def write(tenant_id, channel_id, bucket_id, msg) do
    now = DateTime.utc_now() |> DateTime.to_unix(:millisecond)

    values = [
      {"blob", tenant_id},
      {"blob", channel_id},
      {"int", bucket_id},
      {"blob", msg.message_id},
      {"blob", msg.sender_id},
      {"blob", msg.encrypted_content},
      {"tinyint", msg.content_type},
      {"blob", msg[:reply_to]},
      {"bigint", msg.created_at},
      {"bigint", now}
    ]

    case Xandra.Cluster.execute(Persistence.Scylla, @insert_cql, values, timeout: @xandra_timeout) do
      {:ok, _} -> :ok
      {:error, _} = err -> err
    end
  end

  @spec read(binary(), binary(), integer(), pos_integer()) :: {:ok, [map()]} | {:error, term()}
  def read(tenant_id, channel_id, bucket_id, limit \\ 50) do
    values = [
      {"blob", tenant_id},
      {"blob", channel_id},
      {"int", bucket_id},
      {"int", limit}
    ]

    case Xandra.Cluster.execute(Persistence.Scylla, @select_cql, values, timeout: @xandra_timeout) do
      {:ok, page} ->
        msgs =
          Enum.map(page, fn row ->
            %{
              message_id: row["message_id"],
              sender_id: row["sender_id"],
              encrypted_content: row["encrypted_content"],
              content_type: row["content_type"],
              reply_to: row["reply_to"],
              created_at: row["created_at"],
              server_received_at: row["server_received_at"]
            }
          end)

        {:ok, msgs}

      {:error, _} = err ->
        err
    end
  end

  @spec read_recent(binary(), binary(), pos_integer()) :: {:ok, [map()]}
  def read_recent(tenant_id, channel_id, limit \\ 50) do
    # Cache-aside: check Dragonfly first
    case Persistence.Cache.get_recent_messages(tenant_id, channel_id) do
      {:ok, cached} when length(cached) >= limit ->
        {:ok, Enum.take(cached, limit)}

      _ ->
        result = read_recent_from_scylla(tenant_id, channel_id, limit)

        case result do
          {:ok, msgs} when msgs != [] ->
            Persistence.Cache.put_recent_messages(tenant_id, channel_id, msgs)

          _ ->
            :ok
        end

        result
    end
  end

  defp read_recent_from_scylla(tenant_id, channel_id, limit) do
    now_bucket = MercuryCore.Native.compute_time_bucket(System.os_time(:millisecond))

    case read(tenant_id, channel_id, now_bucket, limit) do
      {:ok, msgs} when length(msgs) < limit ->
        case read(tenant_id, channel_id, now_bucket - 1, limit - length(msgs)) do
          {:ok, older} ->
            {:ok, msgs ++ older}

          {:error, reason} ->
            Logger.warning("ScyllaDB read older bucket failed: #{inspect(reason)}")
            {:ok, msgs}
        end

      {:ok, msgs} ->
        {:ok, msgs}

      {:error, reason} ->
        Logger.warning("ScyllaDB read current bucket failed: #{inspect(reason)}")
        {:ok, []}
    end
  end
end
