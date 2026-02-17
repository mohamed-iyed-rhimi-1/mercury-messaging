defmodule Persistence.Sync do
  @moduledoc """
  Server-side sync engine. Computes deltas from ScyllaDB and applies
  upstream deltas from reconnecting clients.
  """

  alias Persistence.{Repo, Schema.SyncCursor}
  import Ecto.Query

  @max_deltas 100

  @doc "Fetch deltas for a channel since a given HLC timestamp."
  @spec get_deltas(binary(), binary(), non_neg_integer(), pos_integer()) ::
          {:ok, [map()], non_neg_integer(), boolean()}
  def get_deltas(tenant_id, channel_id, since_hlc_wall, limit \\ @max_deltas) do
    limit = min(limit, @max_deltas)

    # Query messages after the given timestamp across recent buckets
    now_ms = System.system_time(:millisecond)
    current_bucket = Gateway.Native.compute_time_bucket(now_ms)
    since_bucket = Gateway.Native.compute_time_bucket(max(since_hlc_wall, 0))

    deltas =
      since_bucket..current_bucket
      |> Enum.flat_map(fn bucket ->
        fetch_messages_after(tenant_id, channel_id, bucket, since_hlc_wall, limit + 1)
      end)
      |> Enum.sort_by(& &1.created_at)
      |> Enum.take(limit + 1)

    has_more = length(deltas) > limit
    deltas = Enum.take(deltas, limit)

    server_hlc = now_ms

    delta_maps =
      Enum.map(deltas, fn msg ->
        %{
          type: "MessageAppend",
          message_id: Base.encode16(msg.message_id),
          sender_id: Base.encode16(msg.sender_id),
          encrypted_content: Base.encode64(msg.encrypted_content),
          content_type: msg.content_type,
          hlc_wall: msg.created_at
        }
      end)

    {:ok, delta_maps, server_hlc, has_more}
  end

  @doc "Apply upstream deltas from a reconnecting client."
  @spec apply_deltas(binary(), binary(), [map()]) ::
          {:ok, non_neg_integer()} | {:error, :too_large}
  def apply_deltas(_tenant_id, _channel_id, deltas) when length(deltas) > 1000 do
    {:error, :too_large}
  end

  def apply_deltas(tenant_id, channel_id, deltas) do
    count =
      Enum.count(deltas, fn delta ->
        apply_single_delta(tenant_id, channel_id, delta)
      end)

    {:ok, count}
  end

  @doc "Update sync cursor for a device."
  @spec update_cursor(Ecto.UUID.t(), Ecto.UUID.t(), Ecto.UUID.t(), Ecto.UUID.t(), map()) :: :ok
  def update_cursor(tenant_id, user_id, device_id, channel_id, hlc) do
    now = DateTime.utc_now()

    Repo.insert!(
      %SyncCursor{
        tenant_id: tenant_id,
        user_id: user_id,
        device_id: device_id,
        channel_id: channel_id,
        last_hlc_wall: Map.get(hlc, :wall, 0),
        last_hlc_counter: Map.get(hlc, :counter, 0),
        last_hlc_node: Map.get(hlc, :node, <<0>>),
        updated_at: now
      },
      on_conflict: {:replace, [:last_hlc_wall, :last_hlc_counter, :last_hlc_node, :updated_at]},
      conflict_target: [:tenant_id, :user_id, :device_id, :channel_id]
    )

    :ok
  end

  @doc "Get sync cursors for all channels of a device."
  # credo:disable-for-next-line Credo.Check.Warning.SpecWithStruct
  @spec get_cursors(Ecto.UUID.t(), Ecto.UUID.t(), Ecto.UUID.t()) :: [%SyncCursor{}]
  def get_cursors(tenant_id, user_id, device_id) do
    SyncCursor
    |> where(tenant_id: ^tenant_id, user_id: ^user_id, device_id: ^device_id)
    |> Repo.all()
  end

  # --- Private ---

  defp fetch_messages_after(tenant_id, channel_id, bucket, since_ts, limit) do
    values = [
      {"blob", tenant_id},
      {"blob", channel_id},
      {"int", bucket},
      {"int", limit}
    ]

    case Xandra.Cluster.execute(
           Persistence.Scylla,
           """
           SELECT message_id, sender_id, encrypted_content, content_type, created_at
           FROM mercury.messages
           WHERE tenant_id = ? AND channel_id = ? AND bucket_id = ?
           ORDER BY message_id DESC
           LIMIT ?
           """,
           values
         ) do
      {:ok, page} ->
        page
        |> Enum.to_list()
        |> Enum.filter(&(row_timestamp(&1) > since_ts))
        |> Enum.map(&row_to_delta/1)

      {:error, _} ->
        []
    end
  end

  defp row_timestamp(row) do
    case row["created_at"] do
      %DateTime{} = dt -> DateTime.to_unix(dt, :millisecond)
      ts when is_integer(ts) -> ts
      _ -> 0
    end
  end

  defp row_to_delta(row) do
    %{
      message_id: row["message_id"],
      sender_id: row["sender_id"],
      encrypted_content: row["encrypted_content"],
      content_type: row["content_type"],
      created_at: row_timestamp(row)
    }
  end

  defp apply_single_delta(tenant_id, channel_id, %{"type" => "MessageAppend"} = delta) do
    msg_id = decode_hex_or_generate(delta["message_id"])
    sender_id = decode_hex_or_default(delta["sender_id"])
    content = decode_b64_or_raw(delta["encrypted_content"])
    ts = delta["hlc_wall"] || System.system_time(:millisecond)
    bucket = Gateway.Native.compute_time_bucket(ts)

    Persistence.Messages.write(tenant_id, channel_id, bucket, %{
      message_id: msg_id,
      sender_id: sender_id,
      encrypted_content: content,
      content_type: delta["content_type"] || 0,
      reply_to: nil,
      created_at: ts
    })
  end

  defp apply_single_delta(tenant_id, channel_id, %{"type" => "ReactionAdd"} = delta) do
    msg_id = Base.decode16!(delta["message_id"], case: :mixed)
    user_id = Base.decode16!(delta["user_id"], case: :mixed)

    values = [
      {"blob", tenant_id},
      {"blob", channel_id},
      {"blob", msg_id},
      {"blob", user_id},
      {"text", delta["emoji"]}
    ]

    _ =
      Xandra.Cluster.execute(
        Persistence.Scylla,
        """
        INSERT INTO mercury.reactions
          (tenant_id, channel_id, message_id, user_id, emoji, created_at)
        VALUES (?, ?, ?, ?, ?, toTimestamp(now()))
        """,
        values
      )

    :ok
  end

  defp apply_single_delta(tenant_id, _channel_id, %{"type" => "ReadPositionUpdate"} = delta) do
    user_id = Base.decode16!(delta["user_id"], case: :mixed)
    channel_id = Base.decode16!(delta["channel_id"], case: :mixed)
    msg_id = Base.decode16!(delta["last_read_message_id"], case: :mixed)
    Persistence.ReadPositions.update(tenant_id, user_id, channel_id, msg_id)
  end

  defp apply_single_delta(_tenant_id, _channel_id, _delta), do: :ok

  defp decode_hex_or_generate(nil), do: Gateway.Native.generate_message_id()

  defp decode_hex_or_generate(hex) do
    case Base.decode16(hex, case: :mixed) do
      {:ok, bin} -> bin
      :error -> Gateway.Native.generate_message_id()
    end
  end

  defp decode_hex_or_default(nil), do: <<0::128>>

  defp decode_hex_or_default(hex) do
    case Base.decode16(hex, case: :mixed) do
      {:ok, bin} -> bin
      :error -> <<0::128>>
    end
  end

  defp decode_b64_or_raw(nil), do: ""

  defp decode_b64_or_raw(val) do
    case Base.decode64(val) do
      {:ok, bin} -> bin
      :error -> val
    end
  end
end
