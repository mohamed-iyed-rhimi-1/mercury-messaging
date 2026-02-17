defmodule Gateway.BinarySocket do
  @moduledoc """
  Raw binary WebSocket handler using WebSock behaviour.
  Replaces Phoenix Channels — no JSON framing, no base64.

  Binary frame format:
    <<type::8, ref::32-little, topic_id::16-little, payload::binary>>

  Frame types:
    0x01 Join    — payload: topic string (e.g. "channel:abc")
    0x02 Leave   — payload: empty
    0x03 Reply   — payload: <<status::8, data::binary>>
    0x04 Push    — payload: <<event::8, data::binary>>
    0x05 Broadcast — payload: <<event::8, data::binary>>
    0x06 Heartbeat — payload: empty
    0x07 Error   — payload: utf8 reason

  Event bytes:
    0x01 msg:send, 0x02 msg:new, 0x03 msg:history, 0x04 msg:typing,
    0x05 msg:read, 0x06 mls:key_package, 0x07 mls:fetch_key_packages,
    0x08 mls:commit, 0x09 mls:welcome, 0x0A mls:remove_member,
    0x0B sync:request, 0x0C sync:push, 0x0D sync:cursor,
    0x0E ch:create, 0x0F presence:join, 0x10 presence:state,
    0x11 status:update
  """
  @behaviour WebSock
  require Logger

  # Frame types
  @join 0x01
  @leave 0x02
  @reply 0x03
  @push 0x04
  @broadcast 0x05
  @heartbeat 0x06
  # Status bytes
  @status_ok 0x00
  @status_error 0x01

  # Event bytes
  @ev_msg_send 0x01
  @ev_msg_new 0x02
  @ev_msg_history 0x03
  @ev_msg_typing 0x04
  @ev_msg_read 0x05
  @ev_mls_key_package 0x06
  @ev_mls_fetch_kp 0x07
  @ev_mls_commit 0x08
  @ev_mls_welcome 0x09
  @ev_mls_remove 0x0A
  @ev_sync_request 0x0B
  @ev_sync_push 0x0C
  @ev_sync_cursor 0x0D
  @ev_ch_create 0x0E
  @ev_presence_join 0x0F
  @ev_status_update 0x11

  @heartbeat_interval 30_000
  @max_missed_heartbeats 3

  # ── WebSock callbacks ──

  @impl WebSock
  def init(state) do
    %{tenant_id: tid, user_id: uid, device_id: did} = state

    :telemetry.execute([:gateway, :connection, :opened], %{count: 1}, %{tenant_id: tid})
    Gateway.ConnectionRegistry.register(tid, uid, did, self())

    heartbeat_ref = Process.send_after(self(), :heartbeat_check, @heartbeat_interval)

    {:ok,
     %{
       tenant_id: tid,
       user_id: uid,
       device_id: did,
       topics: %{},
       next_topic_id: 1,
       topic_ids: %{},
       pubsub_topics: %{},
       heartbeat_ref: heartbeat_ref,
       missed_heartbeats: 0
     }}
  end

  @impl WebSock
  def handle_in({data, opcode: :binary}, state) do
    case data do
      <<@heartbeat, _ref::32-little, _tid::16-little>> ->
        {:ok, %{state | missed_heartbeats: 0}}

      <<@join, ref::32-little, 0::16-little, topic::binary>> ->
        handle_join(ref, topic, state)

      <<@leave, _ref::32-little, topic_id::16-little>> ->
        handle_leave(topic_id, state)

      <<@push, ref::32-little, topic_id::16-little, event::8, payload::binary>> ->
        handle_push(ref, topic_id, event, payload, state)

      _ ->
        {:ok, state}
    end
  end

  def handle_in({_data, opcode: :text}, state) do
    # Ignore text frames
    {:ok, state}
  end

  @impl WebSock
  def handle_info(:heartbeat_check, state) do
    missed = state.missed_heartbeats + 1

    if missed >= @max_missed_heartbeats do
      {:stop, :normal, {1000, "heartbeat timeout"}, state}
    else
      ref = Process.send_after(self(), :heartbeat_check, @heartbeat_interval)
      {:ok, %{state | missed_heartbeats: missed, heartbeat_ref: ref}}
    end
  end

  def handle_info({:binary_broadcast, pubsub_topic, event_byte, payload}, state) do
    case Map.get(state.pubsub_topics, pubsub_topic) do
      nil ->
        {:ok, state}

      topic_id ->
        frame = <<@broadcast, 0::32-little, topic_id::16-little, event_byte::8, payload::binary>>
        {:push, [{:binary, frame}], state}
    end
  end

  def handle_info(_msg, state), do: {:ok, state}

  @impl WebSock
  def terminate(_reason, state) do
    tid = state.tenant_id
    uid = state.user_id
    did = state.device_id
    Gateway.ConnectionRegistry.unregister(tid, uid, did)
    :telemetry.execute([:gateway, :connection, :closed], %{count: 1}, %{tenant_id: tid})

    for {topic, _id} <- state.topics do
      Phoenix.PubSub.unsubscribe(Gateway.PubSub, topic)
    end

    :ok
  end

  # ── Join ──

  defp handle_join(ref, topic, state) do
    case do_join(topic, state) do
      {:ok, topic_id, new_state} ->
        reply = <<@reply, ref::32-little, topic_id::16-little, @status_ok>>
        {:push, [{:binary, reply}], new_state}

      {:error, reason} ->
        reply = <<@reply, ref::32-little, 0::16-little, @status_error, reason::binary>>
        {:push, [{:binary, reply}], state}
    end
  end

  defp do_join("channel:" <> channel_id = topic, state) do
    tid = state.tenant_id
    uid = state.user_id

    if Persistence.Members.member?(tid, :crypto.hash(:md5, channel_id), uid) do
      topic_id = state.next_topic_id
      pubsub_topic = "#{Base.encode16(tid)}:channel:#{channel_id}"
      Phoenix.PubSub.subscribe(Gateway.PubSub, pubsub_topic)
      warm_user_cache(tid, uid)

      new_state = %{
        state
        | topics: Map.put(state.topics, topic, topic_id),
          topic_ids:
            Map.put(state.topic_ids, topic_id, %{
              topic: topic,
              channel_id: channel_id,
              pubsub: pubsub_topic
            }),
          pubsub_topics: Map.put(state.pubsub_topics, pubsub_topic, topic_id),
          next_topic_id: topic_id + 1
      }

      {:ok, topic_id, new_state}
    else
      {:error, "not_a_member"}
    end
  end

  defp do_join("lobby:" <> _tenant = topic, state) do
    topic_id = state.next_topic_id

    new_state = %{
      state
      | topics: Map.put(state.topics, topic, topic_id),
        topic_ids: Map.put(state.topic_ids, topic_id, %{topic: topic}),
        next_topic_id: topic_id + 1
    }

    {:ok, topic_id, new_state}
  end

  defp do_join("presence:" <> channel_id = topic, state) do
    topic_id = state.next_topic_id
    pubsub_topic = "#{Base.encode16(state.tenant_id)}:presence:#{channel_id}"
    Phoenix.PubSub.subscribe(Gateway.PubSub, pubsub_topic)

    new_state = %{
      state
      | topics: Map.put(state.topics, topic, topic_id),
        topic_ids:
          Map.put(state.topic_ids, topic_id, %{
            topic: topic,
            channel_id: channel_id,
            pubsub: pubsub_topic
          }),
        pubsub_topics: Map.put(state.pubsub_topics, pubsub_topic, topic_id),
        next_topic_id: topic_id + 1
    }

    {:ok, topic_id, new_state}
  end

  defp do_join(_topic, _state), do: {:error, "unknown_topic"}

  # ── Leave ──

  defp handle_leave(topic_id, state) do
    case Map.get(state.topic_ids, topic_id) do
      nil ->
        {:ok, state}

      info ->
        if pubsub = info[:pubsub], do: Phoenix.PubSub.unsubscribe(Gateway.PubSub, pubsub)
        topic = info.topic

        new_state = %{
          state
          | topics: Map.delete(state.topics, topic),
            topic_ids: Map.delete(state.topic_ids, topic_id),
            pubsub_topics:
              if(info[:pubsub],
                do: Map.delete(state.pubsub_topics, info.pubsub),
                else: state.pubsub_topics
              )
        }

        {:ok, new_state}
    end
  end

  # ── Push dispatch ──

  defp handle_push(ref, topic_id, event, payload, state) do
    case Map.get(state.topic_ids, topic_id) do
      nil ->
        reply = <<@reply, ref::32-little, topic_id::16-little, @status_error, "not_joined">>
        {:push, [{:binary, reply}], state}

      info ->
        dispatch(ref, topic_id, event, payload, info, state)
    end
  rescue
    e ->
      Logger.error("BinarySocket push crashed: #{inspect(e)}")
      reply = <<@reply, ref::32-little, topic_id::16-little, @status_error, "internal_error">>
      {:push, [{:binary, reply}], state}
  end

  # ── Message handlers ──

  defp dispatch(ref, topic_id, @ev_msg_send, envelope_bin, info, state) do
    channel_id = info.channel_id
    tid = state.tenant_id
    uid = state.user_id
    channel_id_bin = :crypto.hash(:md5, channel_id)

    with {_tid, _cid, _sid, msg_id, ts, payload} <- Gateway.Native.envelope_decode(envelope_bin),
         {:ok, _} <- Gateway.Native.validate_message(tid, channel_id_bin, uid, payload, 0),
         true <- Gateway.RateLimiter.allow?(tid, uid) do
      bucket = Gateway.Native.compute_time_bucket(ts)

      persist_message(tid, channel_id_bin, bucket, %{
        message_id: msg_id,
        sender_id: uid,
        encrypted_content: payload,
        content_type: 0,
        reply_to: nil,
        created_at: ts
      })

      out_bin = Gateway.Native.envelope_encode(tid, channel_id_bin, uid, msg_id, ts, payload)
      broadcast_binary(info.pubsub, topic_id, @ev_msg_new, out_bin)

      reply_data = msg_id
      reply = <<@reply, ref::32-little, topic_id::16-little, @status_ok, reply_data::binary>>
      {:push, [{:binary, reply}], state}
    else
      false ->
        reply = <<@reply, ref::32-little, topic_id::16-little, @status_error, "rate_limited">>
        {:push, [{:binary, reply}], state}

      _ ->
        reply = <<@reply, ref::32-little, topic_id::16-little, @status_error, "invalid">>
        {:push, [{:binary, reply}], state}
    end
  end

  defp dispatch(ref, topic_id, @ev_msg_history, payload, info, state) do
    tid = state.tenant_id
    channel_id_bin = :crypto.hash(:md5, info.channel_id)

    <<limit::32-little>> =
      if byte_size(payload) >= 4, do: binary_part(payload, 0, 4), else: <<50::32-little>>

    limit = min(limit, 100)

    {:ok, msgs} = Persistence.Messages.read_recent(tid, channel_id_bin, limit)

    envelopes =
      Enum.map(msgs, fn m ->
        Gateway.Native.envelope_encode(
          tid,
          channel_id_bin,
          m.sender_id,
          m.message_id,
          m.created_at,
          m.encrypted_content
        )
      end)

    # Pack: <<count::32-little, len1::32-little, env1::binary, len2::32-little, env2::binary, ...>>
    packed = pack_envelopes(envelopes)
    reply = <<@reply, ref::32-little, topic_id::16-little, @status_ok, packed::binary>>
    {:push, [{:binary, reply}], state}
  end

  defp dispatch(_ref, topic_id, @ev_msg_typing, _payload, info, state) do
    bin = Gateway.Native.typing_encode(state.user_id)
    broadcast_binary_from(info.pubsub, topic_id, @ev_msg_typing, bin, self())
    {:ok, state}
  end

  defp dispatch(ref, topic_id, @ev_msg_read, capnp_bin, info, state) do
    tid = state.tenant_id
    uid = state.user_id
    {_uid, mid} = Gateway.Native.read_receipt_decode(capnp_bin)

    persist_read_position(tid, uid, info.channel_id, mid)

    out_bin = Gateway.Native.read_receipt_encode(uid, mid)
    broadcast_binary_from(info.pubsub, topic_id, @ev_msg_read, out_bin, self())

    reply = <<@reply, ref::32-little, topic_id::16-little, @status_ok>>
    {:push, [{:binary, reply}], state}
  end

  defp dispatch(ref, topic_id, @ev_mls_key_package, capnp_bin, _info, state) do
    kp = Gateway.Native.mls_key_package_capnp_decode(capnp_bin)
    tid = state.tenant_id
    device_id = state.device_id

    case Persistence.KeyPackages.upload(tid, device_id, kp) do
      :ok ->
        reply = <<@reply, ref::32-little, topic_id::16-little, @status_ok>>
        {:push, [{:binary, reply}], state}
    end
  end

  defp dispatch(ref, topic_id, @ev_mls_fetch_kp, uid_bin, _info, state) do
    tid = state.tenant_id
    {:ok, packages} = Persistence.KeyPackages.fetch(tid, uid_bin)
    bin = Gateway.Native.mls_key_package_list_encode(packages)

    reply = <<@reply, ref::32-little, topic_id::16-little, @status_ok, bin::binary>>
    {:push, [{:binary, reply}], state}
  end

  defp dispatch(ref, topic_id, @ev_mls_commit, capnp_bin, info, state) do
    _commit = Gateway.Native.mls_commit_capnp_decode(capnp_bin)
    broadcast_binary_from(info.pubsub, topic_id, @ev_mls_commit, capnp_bin, self())

    reply = <<@reply, ref::32-little, topic_id::16-little, @status_ok>>
    {:push, [{:binary, reply}], state}
  end

  defp dispatch(ref, topic_id, @ev_mls_welcome, payload, _info, state) do
    # payload: <<user_id_len::16-little, user_id::binary, welcome::binary>>
    <<uid_len::16-little, uid::binary-size(uid_len), welcome_capnp::binary>> = payload
    tid = state.tenant_id
    uid_hex = Base.encode16(uid)

    Phoenix.PubSub.broadcast(
      Gateway.PubSub,
      "#{Base.encode16(tid)}:user:#{uid_hex}",
      {:binary_broadcast, 0, @ev_mls_welcome, welcome_capnp}
    )

    reply = <<@reply, ref::32-little, topic_id::16-little, @status_ok>>
    {:push, [{:binary, reply}], state}
  end

  defp dispatch(ref, topic_id, @ev_mls_remove, payload, info, state) do
    # payload: <<user_id::16-bytes, commit_capnp::binary>>
    <<uid::binary-size(16), commit_capnp::binary>> = payload
    tid = state.tenant_id
    channel_id_bin = :crypto.hash(:md5, info.channel_id)

    _commit = Gateway.Native.mls_commit_capnp_decode(commit_capnp)
    Persistence.Members.remove_member(tid, channel_id_bin, uid)
    broadcast_binary_from(info.pubsub, topic_id, @ev_mls_commit, commit_capnp, self())

    reply = <<@reply, ref::32-little, topic_id::16-little, @status_ok>>
    {:push, [{:binary, reply}], state}
  end

  defp dispatch(ref, topic_id, @ev_sync_request, payload, info, state) do
    tid = state.tenant_id
    channel_id_bin = :crypto.hash(:md5, info.channel_id)

    <<since_wall::64-little, limit::32-little, last_counter::32-little>> =
      if byte_size(payload) >= 16,
        do: binary_part(payload, 0, 16),
        else: <<0::64-little, 100::32-little, 0::32-little>>

    limit = min(limit, 100)
    node_id = state.user_id

    {:ok, deltas, _raw_hlc, has_more} =
      Persistence.Sync.get_deltas(tid, channel_id_bin, since_wall, limit)

    {merged_wall, _merged_counter} =
      Gateway.Native.hlc_merge(
        System.system_time(:millisecond),
        0,
        node_id,
        since_wall,
        last_counter,
        node_id
      )

    envelopes =
      Enum.map(deltas, fn d ->
        {:ok, mid} = Base.decode16(d.message_id, case: :mixed)
        {:ok, sid} = Base.decode16(d.sender_id, case: :mixed)
        {:ok, content} = Base.decode64(d.encrypted_content)
        Gateway.Native.envelope_encode(tid, channel_id_bin, sid, mid, d.hlc_wall, content)
      end)

    packed = pack_envelopes(envelopes)
    has_more_byte = if has_more, do: 1, else: 0

    reply_data = <<merged_wall::64-little, has_more_byte::8, packed::binary>>
    reply = <<@reply, ref::32-little, topic_id::16-little, @status_ok, reply_data::binary>>
    {:push, [{:binary, reply}], state}
  end

  defp dispatch(ref, topic_id, @ev_sync_push, payload, info, state) do
    tid = state.tenant_id
    channel_id_bin = :crypto.hash(:md5, info.channel_id)

    envelopes = unpack_envelopes(payload)

    deltas =
      Enum.map(envelopes, fn env_bin ->
        {_tid, _cid, sid, mid, ts, pl} = Gateway.Native.envelope_decode(env_bin)

        %{
          "type" => "MessageAppend",
          "message_id" => Base.encode16(mid),
          "sender_id" => Base.encode16(sid),
          "encrypted_content" => Base.encode64(pl),
          "content_type" => 0,
          "hlc_wall" => ts
        }
      end)

    case Persistence.Sync.apply_deltas(tid, channel_id_bin, deltas) do
      {:ok, count} ->
        publish_sync_fanout(state, deltas)

        {wall, _counter} =
          Gateway.Native.hlc_tick(System.system_time(:millisecond), 0, state.user_id)

        reply_data = <<count::32-little, wall::64-little>>
        reply = <<@reply, ref::32-little, topic_id::16-little, @status_ok, reply_data::binary>>
        {:push, [{:binary, reply}], state}

      {:error, :too_large} ->
        reply = <<@reply, ref::32-little, topic_id::16-little, @status_error, "batch_too_large">>
        {:push, [{:binary, reply}], state}
    end
  end

  defp dispatch(_ref, _topic_id, @ev_sync_cursor, payload, info, state) do
    if info[:channel_id] do
      <<wall::64-little, counter::32-little>> =
        if byte_size(payload) >= 12,
          do: binary_part(payload, 0, 12),
          else: <<0::64-little, 0::32-little>>

      hlc = %{wall: wall, counter: counter, node: <<0>>}

      Persistence.Sync.update_cursor(
        state.tenant_id,
        state.user_id,
        state.device_id,
        info.channel_id,
        hlc
      )
    end

    {:ok, state}
  end

  defp dispatch(ref, topic_id, @ev_ch_create, payload, _info, state) do
    # payload: <<channel_type::8, name_len::16-little, name::binary>>
    <<ct::8, rest::binary>> = payload

    name =
      if byte_size(rest) >= 2 do
        <<nlen::16-little, n::binary-size(nlen)>> = rest
        n
      else
        nil
      end

    tid = state.tenant_id
    uid = state.user_id

    case Gateway.Native.validate_channel(tid, ct, name) do
      {:ok, _} ->
        channel_id = Gateway.Native.generate_channel_id()
        channel_id_bin = :crypto.hash(:md5, Base.encode16(channel_id))

        try do
          Persistence.Members.add_member(tid, channel_id_bin, uid)
        rescue
          _ -> Logger.debug("Membership insert deferred")
        end

        reply = <<@reply, ref::32-little, topic_id::16-little, @status_ok, channel_id::binary>>
        {:push, [{:binary, reply}], state}

      {:error, reason} ->
        reply =
          <<@reply, ref::32-little, topic_id::16-little, @status_error,
            to_string(reason)::binary>>

        {:push, [{:binary, reply}], state}
    end
  end

  defp dispatch(ref, topic_id, @ev_presence_join, _payload, info, state) do
    uid = state.user_id
    did = state.device_id

    if info[:channel_id] do
      Presence.Tracker.track(
        self(),
        info.pubsub,
        Base.encode16(uid),
        %{
          status: :online,
          device_id: Base.encode16(did),
          last_seen: System.system_time(:millisecond)
        }
      )
    end

    reply = <<@reply, ref::32-little, topic_id::16-little, @status_ok>>
    {:push, [{:binary, reply}], state}
  end

  defp dispatch(ref, topic_id, @ev_status_update, <<status::8>>, info, state) do
    uid = Base.encode16(state.user_id)
    status_atom = if status == 1, do: :away, else: :online

    if info[:pubsub] do
      Presence.Tracker.update(self(), info.pubsub, uid, fn meta ->
        %{meta | status: status_atom, last_seen: System.system_time(:millisecond)}
      end)
    end

    reply = <<@reply, ref::32-little, topic_id::16-little, @status_ok>>
    {:push, [{:binary, reply}], state}
  end

  defp dispatch(ref, topic_id, _event, _payload, _info, state) do
    reply = <<@reply, ref::32-little, topic_id::16-little, @status_error, "unknown_event">>
    {:push, [{:binary, reply}], state}
  end

  # ── Helpers ──

  defp broadcast_binary(pubsub_topic, _topic_id, event_byte, payload) do
    Phoenix.PubSub.broadcast(
      Gateway.PubSub,
      pubsub_topic,
      {:binary_broadcast, pubsub_topic, event_byte, payload}
    )
  end

  defp broadcast_binary_from(pubsub_topic, _topic_id, event_byte, payload, from_pid) do
    Phoenix.PubSub.broadcast_from(
      Gateway.PubSub,
      from_pid,
      pubsub_topic,
      {:binary_broadcast, pubsub_topic, event_byte, payload}
    )
  end

  defp pack_envelopes(envelopes) do
    count = length(envelopes)
    parts = Enum.map(envelopes, fn e -> <<byte_size(e)::32-little, e::binary>> end)
    IO.iodata_to_binary([<<count::32-little>> | parts])
  end

  defp unpack_envelopes(<<count::32-little, rest::binary>>) do
    unpack_envelopes_loop(rest, count, [])
  end

  defp unpack_envelopes(_), do: []

  defp unpack_envelopes_loop(_rest, 0, acc), do: Enum.reverse(acc)

  defp unpack_envelopes_loop(<<len::32-little, env::binary-size(len), rest::binary>>, n, acc) do
    unpack_envelopes_loop(rest, n - 1, [env | acc])
  end

  defp unpack_envelopes_loop(_, _, acc), do: Enum.reverse(acc)

  defp persist_message(tenant_id, channel_id, bucket, msg) do
    Persistence.Cache.invalidate_recent_messages(tenant_id, channel_id)
    publish_cache_invalidation(tenant_id, "recent", channel_id)

    if Process.whereis(Persistence.Nats) do
      Persistence.Events.publish_message(tenant_id, channel_id, %{
        message_id: Base.encode16(msg.message_id),
        sender_id: Base.encode16(msg.sender_id),
        content_type: msg.content_type,
        created_at: msg.created_at
      })
    end

    if scylla_enabled?(), do: Task.start(fn -> do_persist(tenant_id, channel_id, bucket, msg) end)
  end

  defp do_persist(tenant_id, channel_id, bucket, msg) do
    case Persistence.Messages.write(tenant_id, channel_id, bucket, msg) do
      :ok -> :ok
      {:error, reason} -> Logger.warning("ScyllaDB write failed: #{inspect(reason)}")
    end
  end

  defp scylla_enabled? do
    Application.get_env(:persistence, Persistence.Scylla, [])[:enabled] == true
  end

  defp persist_read_position(tenant_id, user_id, channel_id, message_id) do
    if scylla_enabled?() do
      channel_id_bin = :crypto.hash(:md5, channel_id)

      Task.start(fn ->
        Persistence.ReadPositions.update(tenant_id, user_id, channel_id_bin, message_id)
      end)
    end

    :ok
  end

  defp publish_cache_invalidation(tenant_id, type, target_id) do
    if Process.whereis(Persistence.Nats) do
      msg =
        Jason.encode!(%{
          type: type,
          tenant_id: Base.encode16(tenant_id),
          target_id: Base.encode16(target_id)
        })

      _ = Gnat.pub(Persistence.Nats, "mercury.cache.invalidate", msg)
    end

    :ok
  end

  defp publish_sync_fanout(state, deltas) do
    tid = state.tenant_id
    uid = state.user_id
    did = state.device_id

    if Process.whereis(Persistence.Nats) do
      topic = "mercury.sync.#{Base.encode16(tid)}.#{Base.encode16(uid)}"
      msg = Jason.encode!(%{device_id: Base.encode16(did), deltas: deltas})
      _ = Gnat.pub(Persistence.Nats, topic, msg)
    end

    :ok
  end

  defp warm_user_cache(tenant_id, user_id) do
    case Persistence.Cache.get_user(tenant_id, user_id) do
      {:ok, _} ->
        :ok

      :miss ->
        tid_uuid = uuid_from_binary(tenant_id)
        uid_uuid = uuid_from_binary(user_id)

        case Persistence.Repo.get_by(Persistence.Schema.User,
               tenant_id: tid_uuid,
               user_id: uid_uuid
             ) do
          nil ->
            :ok

          user ->
            Persistence.Cache.put_user(tenant_id, user_id, %{
              user_id: user.user_id,
              display_name: user.display_name,
              avatar_url: user.avatar_url
            })
        end
    end
  rescue
    _ -> :ok
  end

  defp uuid_from_binary(<<a::32, b::16, c::16, d::16, e::48>>) do
    :io_lib.format("~8.16.0b-~4.16.0b-~4.16.0b-~4.16.0b-~12.16.0b", [a, b, c, d, e])
    |> IO.iodata_to_binary()
  end

  defp uuid_from_binary(_), do: nil
end
