defmodule Persistence.Cache do
  @moduledoc "Dragonfly/Redis cache — cache-aside pattern for hot data."

  @user_ttl 300
  @members_ttl 60
  @recent_ttl 30

  # ── User cache ──

  @spec get_user(binary(), binary()) :: {:ok, map()} | :miss
  def get_user(tenant_id, user_id) do
    key = user_key(tenant_id, user_id)

    case safe_command(["GET", key]) do
      {:ok, nil} -> :miss
      {:ok, json} -> {:ok, Jason.decode!(json)}
      :error -> :miss
    end
  end

  @spec put_user(binary(), binary(), map()) :: :ok
  def put_user(tenant_id, user_id, user_data) do
    key = user_key(tenant_id, user_id)
    safe_command(["SETEX", key, @user_ttl, Jason.encode!(user_data)])
    :ok
  end

  @spec invalidate_user(binary(), binary()) :: :ok
  def invalidate_user(tenant_id, user_id) do
    safe_command(["DEL", user_key(tenant_id, user_id)])
    :ok
  end

  # ── Channel members cache ──

  @spec get_channel_members(binary(), binary()) :: {:ok, [binary()]} | :miss
  def get_channel_members(tenant_id, channel_id) do
    key = members_key(tenant_id, channel_id)

    case safe_command(["SMEMBERS", key]) do
      {:ok, []} -> :miss
      {:ok, members} -> {:ok, members}
      :error -> :miss
    end
  end

  @spec put_channel_members(binary(), binary(), [binary()]) :: :ok
  def put_channel_members(tenant_id, channel_id, member_ids) when member_ids != [] do
    key = members_key(tenant_id, channel_id)

    safe_pipeline([
      ["DEL", key],
      ["SADD", key | member_ids],
      ["EXPIRE", key, @members_ttl]
    ])

    :ok
  end

  def put_channel_members(_tenant_id, _channel_id, []), do: :ok

  @spec invalidate_channel_members(binary(), binary()) :: :ok
  def invalidate_channel_members(tenant_id, channel_id) do
    safe_command(["DEL", members_key(tenant_id, channel_id)])
    :ok
  end

  # ── Recent messages cache ──

  @spec get_recent_messages(binary(), binary()) :: {:ok, [map()]} | :miss
  def get_recent_messages(tenant_id, channel_id) do
    key = recent_key(tenant_id, channel_id)

    case safe_command(["GET", key]) do
      {:ok, nil} ->
        :miss

      {:ok, json} ->
        msgs =
          json
          |> Jason.decode!()
          |> Enum.map(&deserialize_message/1)

        {:ok, msgs}

      :error ->
        :miss
    end
  end

  @spec put_recent_messages(binary(), binary(), [map()]) :: :ok
  def put_recent_messages(tenant_id, channel_id, messages) do
    key = recent_key(tenant_id, channel_id)
    serialized = Enum.map(messages, &serialize_message/1)
    safe_command(["SETEX", key, @recent_ttl, Jason.encode!(serialized)])
    :ok
  end

  defp serialize_message(m) do
    %{
      "mid" => Base.encode64(m.message_id),
      "sid" => Base.encode64(m.sender_id),
      "ec" => Base.encode64(m.encrypted_content),
      "ct" => m.content_type,
      "ca" => m.created_at,
      "rt" => if(m[:reply_to], do: Base.encode64(m.reply_to))
    }
  end

  defp deserialize_message(m) do
    %{
      message_id: Base.decode64!(m["mid"]),
      sender_id: Base.decode64!(m["sid"]),
      encrypted_content: Base.decode64!(m["ec"]),
      content_type: m["ct"],
      created_at: m["ca"],
      reply_to: if(m["rt"], do: Base.decode64!(m["rt"]))
    }
  end

  @spec invalidate_recent_messages(binary(), binary()) :: :ok
  def invalidate_recent_messages(tenant_id, channel_id) do
    safe_command(["DEL", recent_key(tenant_id, channel_id)])
    :ok
  end

  # ── Rate limiter ──

  @spec rate_check(binary(), binary(), pos_integer()) :: :allow | :deny
  def rate_check(tenant_id, user_id, limit) do
    key = rate_key(tenant_id, user_id)

    case safe_pipeline([["INCR", key], ["EXPIRE", key, 1]]) do
      {:ok, [count, _]} when is_integer(count) and count <= limit -> :allow
      {:ok, _} -> :deny
      :error -> :allow
    end
  end

  # ── Helpers ──

  defp user_key(t, u), do: "#{Base.encode16(t)}:user:#{Base.encode16(u)}"
  defp members_key(t, c), do: "#{Base.encode16(t)}:ch:#{Base.encode16(c)}:members"
  defp recent_key(t, c), do: "#{Base.encode16(t)}:ch:#{Base.encode16(c)}:recent"
  defp rate_key(t, u), do: "#{Base.encode16(t)}:rl:#{Base.encode16(u)}"

  defp safe_command(cmd) do
    if Process.whereis(Persistence.Redis) do
      case Redix.command(Persistence.Redis, cmd) do
        {:ok, _} = ok ->
          ok

        {:error, reason} ->
          Logger.warning("Cache command failed: #{inspect(reason)}")
          :error
      end
    else
      :error
    end
  end

  defp safe_pipeline(cmds) do
    if Process.whereis(Persistence.Redis) do
      case Redix.pipeline(Persistence.Redis, cmds) do
        {:ok, _} = ok ->
          ok

        {:error, reason} ->
          Logger.warning("Cache pipeline failed: #{inspect(reason)}")
          :error
      end
    else
      :error
    end
  end
end
