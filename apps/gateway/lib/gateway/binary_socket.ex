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
    0x11 status:update, 0x12 mls:members, 0x13 mls:group_info, 0x14 mls:cek
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
  @ev_mls_members 0x12
  @ev_mls_group_info 0x13
  @ev_mls_cek 0x14

  @heartbeat_interval 30_000
  @max_missed_heartbeats 3

  # ── WebSock callbacks ──

  @impl WebSock
  def init(state) do
    %{tenant_id: tid, user_id: uid, device_id: did} = state

    :telemetry.execute([:gateway, :connection, :opened], %{count: 1}, %{tenant_id: tid})
    Gateway.ConnectionRegistry.register(tid, uid, did, self())

    case Persistence.Provisioning.ensure_device(tid, uid, did) do
      :ok -> :ok
      {:error, reason} -> Logger.error("Provisioning failed: #{inspect(reason)}")
    end

    Gateway.SyncConsumer.subscribe(tid, uid)
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
    if state.heartbeat_ref, do: Process.cancel_timer(state.heartbeat_ref)
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
    Gateway.SyncConsumer.unsubscribe(tid, uid)
    :telemetry.execute([:gateway, :connection, :closed], %{count: 1}, %{tenant_id: tid})

    if state.heartbeat_ref, do: Process.cancel_timer(state.heartbeat_ref)

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

    with {:ok, channel_id_bin} <- channel_id_to_bin(channel_id),
         {:ok, topic_id, new_state} <- allocate_topic_id(state) do
      case Persistence.Members.member?(tid, channel_id_bin, uid) do
        true ->
          pubsub_topic = "#{Base.encode16(tid)}:channel:#{channel_id}"
          Phoenix.PubSub.subscribe(Gateway.PubSub, pubsub_topic)
          warm_user_cache(tid, uid)

          new_state = %{
            new_state
            | topics: Map.put(new_state.topics, topic, topic_id),
              topic_ids:
                Map.put(new_state.topic_ids, topic_id, %{
                  topic: topic,
                  channel_id: channel_id,
                  pubsub: pubsub_topic
                }),
              pubsub_topics: Map.put(new_state.pubsub_topics, pubsub_topic, topic_id)
          }

          # Notify existing channel members that a new user joined (for MLS key exchange)
          broadcast_binary_from(pubsub_topic, topic_id, @ev_presence_join, uid, self())

          {:ok, topic_id, new_state}

        false ->
          {:error, "not_a_member"}

        {:error, _} ->
          {:error, "membership_check_failed"}
      end
    end
  end

  defp do_join("lobby:" <> _tenant = topic, state) do
    case allocate_topic_id(state) do
      {:ok, topic_id, new_state} ->
        new_state = %{
          new_state
          | topics: Map.put(new_state.topics, topic, topic_id),
            topic_ids: Map.put(new_state.topic_ids, topic_id, %{topic: topic})
        }

        {:ok, topic_id, new_state}

      {:error, _} = err ->
        err
    end
  end

  defp do_join("presence:" <> channel_id = topic, state) do
    case allocate_topic_id(state) do
      {:ok, topic_id, new_state} ->
        pubsub_topic = "#{Base.encode16(new_state.tenant_id)}:presence:#{channel_id}"
        Phoenix.PubSub.subscribe(Gateway.PubSub, pubsub_topic)

        new_state = %{
          new_state
          | topics: Map.put(new_state.topics, topic, topic_id),
            topic_ids:
              Map.put(new_state.topic_ids, topic_id, %{
                topic: topic,
                channel_id: channel_id,
                pubsub: pubsub_topic
              }),
            pubsub_topics: Map.put(new_state.pubsub_topics, pubsub_topic, topic_id)
        }

        {:ok, topic_id, new_state}

      {:error, _} = err ->
        err
    end
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
        # Events that require a channel topic — reject early if on lobby/presence
        if event in [
             @ev_msg_send, @ev_msg_history, @ev_msg_typing, @ev_msg_read,
             @ev_mls_commit, @ev_mls_welcome, @ev_mls_remove, @ev_mls_members,
             @ev_mls_group_info, @ev_mls_cek,
             @ev_sync_request, @ev_sync_push, @ev_sync_cursor
           ] and not Map.has_key?(info, :channel_id) do
          reply = <<@reply, ref::32-little, topic_id::16-little, @status_error, "not_a_channel">>
          {:push, [{:binary, reply}], state}
        else
          dispatch(ref, topic_id, event, payload, info, state)
        end
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

    with {:ok, channel_id_bin} <- channel_id_to_bin(channel_id),
         {:ok, {_tid, _cid, _sid, msg_id, ts, payload}} <-
           safe_nif_call(fn -> Gateway.Native.envelope_decode(envelope_bin) end),
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

      {:error, reason} ->
        reply =
          <<@reply, ref::32-little, topic_id::16-little, @status_error,
            to_string(reason)::binary>>

        {:push, [{:binary, reply}], state}
    end
  end

  defp dispatch(ref, topic_id, @ev_msg_history, payload, info, state) do
    tid = state.tenant_id

    with {:ok, channel_id_bin} <- channel_id_to_bin(info.channel_id) do
      <<limit::32-little>> =
        if byte_size(payload) >= 4, do: binary_part(payload, 0, 4), else: <<50::32-little>>

      limit = min(limit, 100)

      case Persistence.Messages.read_recent(tid, channel_id_bin, limit) do
        {:ok, msgs} ->
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

          packed = pack_envelopes(envelopes)
          reply = <<@reply, ref::32-little, topic_id::16-little, @status_ok, packed::binary>>
          {:push, [{:binary, reply}], state}
      end
    else
      {:error, reason} ->
        reply =
          <<@reply, ref::32-little, topic_id::16-little, @status_error,
            to_string(reason)::binary>>

        {:push, [{:binary, reply}], state}
    end
  end

  defp dispatch(_ref, topic_id, @ev_msg_typing, _payload, info, state) do
    bin = Gateway.Native.typing_encode(state.user_id)
    broadcast_binary_from(info.pubsub, topic_id, @ev_msg_typing, bin, self())
    {:ok, state}
  end

  defp dispatch(ref, topic_id, @ev_msg_read, capnp_bin, info, state) do
    tid = state.tenant_id
    uid = state.user_id

    with {:ok, {_uid, mid}} <- safe_nif_call(fn -> Gateway.Native.read_receipt_decode(capnp_bin) end) do
      persist_read_position(tid, uid, info.channel_id, mid)

      out_bin = Gateway.Native.read_receipt_encode(uid, mid)
      broadcast_binary_from(info.pubsub, topic_id, @ev_msg_read, out_bin, self())

      reply = <<@reply, ref::32-little, topic_id::16-little, @status_ok>>
      {:push, [{:binary, reply}], state}
    else
      {:error, reason} ->
        reply =
          <<@reply, ref::32-little, topic_id::16-little, @status_error,
            to_string(reason)::binary>>

        {:push, [{:binary, reply}], state}
    end
  end

  defp dispatch(ref, topic_id, @ev_mls_key_package, capnp_bin, info, state) do
    with {:ok, kp} <- safe_nif_call(fn -> Gateway.Native.mls_key_package_capnp_decode(capnp_bin) end) do
      tid_uuid = uuid_from_binary(state.tenant_id)
      did_uuid = uuid_from_binary(state.device_id)

      if tid_uuid && did_uuid do
        case Persistence.KeyPackages.upload(tid_uuid, did_uuid, kp) do
          :ok ->
            if info[:pubsub] do
              broadcast_binary(info.pubsub, topic_id, @ev_mls_key_package, state.user_id)
            end

            reply = <<@reply, ref::32-little, topic_id::16-little, @status_ok>>
            {:push, [{:binary, reply}], state}

          {:error, reason} ->
            reply =
              <<@reply, ref::32-little, topic_id::16-little, @status_error,
                to_string(reason)::binary>>

            {:push, [{:binary, reply}], state}
        end
      else
        reply = <<@reply, ref::32-little, topic_id::16-little, @status_error, "invalid_id">>
        {:push, [{:binary, reply}], state}
      end
    else
      {:error, reason} ->
        reply =
          <<@reply, ref::32-little, topic_id::16-little, @status_error,
            to_string(reason)::binary>>

        {:push, [{:binary, reply}], state}
    end
  end

  defp dispatch(ref, topic_id, @ev_mls_fetch_kp, uid_bin, _info, state) do
    tid_uuid = uuid_from_binary(state.tenant_id)
    uid_uuid = uuid_from_binary(uid_bin)

    if tid_uuid && uid_uuid do
      case Persistence.KeyPackages.fetch(tid_uuid, uid_uuid) do
        {:ok, packages} ->
          bin = Gateway.Native.mls_key_package_list_encode(packages)
          reply = <<@reply, ref::32-little, topic_id::16-little, @status_ok, bin::binary>>
          {:push, [{:binary, reply}], state}
      end
    else
      bin = Gateway.Native.mls_key_package_list_encode([])
      reply = <<@reply, ref::32-little, topic_id::16-little, @status_ok, bin::binary>>
      {:push, [{:binary, reply}], state}
    end
  end

  defp dispatch(ref, topic_id, @ev_mls_commit, capnp_bin, info, state) do
    case safe_nif_call(fn -> Gateway.Native.mls_commit_capnp_decode(capnp_bin) end) do
      {:ok, _commit} ->
        broadcast_binary_from(info.pubsub, topic_id, @ev_mls_commit, capnp_bin, self())
        reply = <<@reply, ref::32-little, topic_id::16-little, @status_ok>>
        {:push, [{:binary, reply}], state}

      {:error, reason} ->
        reply =
          <<@reply, ref::32-little, topic_id::16-little, @status_error,
            to_string(reason)::binary>>

        {:push, [{:binary, reply}], state}
    end
  end

  defp dispatch(ref, topic_id, @ev_mls_welcome, payload, info, state)
       when byte_size(payload) > 2 do
    <<uid_len::16-little, rest::binary>> = payload

    if byte_size(rest) >= uid_len do
      broadcast_binary(info.pubsub, topic_id, @ev_mls_welcome, payload)
      reply = <<@reply, ref::32-little, topic_id::16-little, @status_ok>>
      {:push, [{:binary, reply}], state}
    else
      reply = <<@reply, ref::32-little, topic_id::16-little, @status_error, "malformed_welcome">>
      {:push, [{:binary, reply}], state}
    end
  end

  defp dispatch(ref, topic_id, @ev_mls_remove, payload, info, state)
       when byte_size(payload) >= 16 do
    <<uid::binary-size(16), commit_capnp::binary>> = payload
    tid = state.tenant_id
    caller = state.user_id

    with {:ok, channel_id_bin} <- channel_id_to_bin(info.channel_id) do
      case Persistence.Members.get_role(tid, channel_id_bin, caller) do
        {:ok, role} when role >= 1 ->
          case safe_nif_call(fn -> Gateway.Native.mls_commit_capnp_decode(commit_capnp) end) do
            {:ok, _commit} ->
              case Persistence.Members.remove_member(tid, channel_id_bin, uid) do
                :ok -> :ok
                {:error, reason} -> Logger.warning("remove_member failed: #{inspect(reason)}")
              end

              broadcast_binary_from(info.pubsub, topic_id, @ev_mls_commit, commit_capnp, self())
              reply = <<@reply, ref::32-little, topic_id::16-little, @status_ok>>
              {:push, [{:binary, reply}], state}

            {:error, reason} ->
              reply =
                <<@reply, ref::32-little, topic_id::16-little, @status_error,
                  to_string(reason)::binary>>

              {:push, [{:binary, reply}], state}
          end

        {:error, _} ->
          reply = <<@reply, ref::32-little, topic_id::16-little, @status_error, "unauthorized">>
          {:push, [{:binary, reply}], state}

        _ ->
          reply = <<@reply, ref::32-little, topic_id::16-little, @status_error, "unauthorized">>
          {:push, [{:binary, reply}], state}
      end
    else
      {:error, reason} ->
        reply =
          <<@reply, ref::32-little, topic_id::16-little, @status_error,
            to_string(reason)::binary>>

        {:push, [{:binary, reply}], state}
    end
  end

  defp dispatch(ref, topic_id, @ev_sync_request, payload, info, state) do
    tid = state.tenant_id

    with {:ok, channel_id_bin} <- channel_id_to_bin(info.channel_id) do
      <<since_wall::64-little, limit::32-little, last_counter::32-little>> =
        if byte_size(payload) >= 16,
          do: binary_part(payload, 0, 16),
          else: <<0::64-little, 100::32-little, 0::32-little>>

      limit = min(limit, 100)
      node_id = state.user_id

      case Persistence.Sync.get_deltas(tid, channel_id_bin, since_wall, limit) do
        {:ok, deltas, _raw_hlc, has_more} ->
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
            Enum.reduce(deltas, [], fn d, acc ->
              with {:ok, mid} <- Base.decode16(d.message_id, case: :mixed),
                   {:ok, sid} <- Base.decode16(d.sender_id, case: :mixed),
                   {:ok, content} <- Base.decode64(d.encrypted_content) do
                env =
                  Gateway.Native.envelope_encode(
                    tid,
                    channel_id_bin,
                    sid,
                    mid,
                    d.hlc_wall,
                    content
                  )

                [env | acc]
              else
                _ ->
                  Logger.warning("sync:request skipping delta with bad encoding")
                  acc
              end
            end)
            |> Enum.reverse()

          packed = pack_envelopes(envelopes)
          has_more_byte = if has_more, do: 1, else: 0

          reply_data = <<merged_wall::64-little, has_more_byte::8, packed::binary>>
          reply = <<@reply, ref::32-little, topic_id::16-little, @status_ok, reply_data::binary>>
          {:push, [{:binary, reply}], state}
      end
    else
      {:error, reason} ->
        reply =
          <<@reply, ref::32-little, topic_id::16-little, @status_error,
            to_string(reason)::binary>>

        {:push, [{:binary, reply}], state}
    end
  end

  defp dispatch(ref, topic_id, @ev_sync_push, payload, info, state) do
    tid = state.tenant_id

    with {:ok, channel_id_bin} <- channel_id_to_bin(info.channel_id) do
      envelopes = unpack_envelopes(payload)

      {deltas, _errors} =
        Enum.reduce(envelopes, {[], 0}, fn env_bin, {acc, errs} ->
          case safe_nif_call(fn -> Gateway.Native.envelope_decode(env_bin) end) do
            {:ok, {_tid, _cid, sid, mid, ts, pl}} ->
              delta = %{
                "type" => "MessageAppend",
                "message_id" => Base.encode16(mid),
                "sender_id" => Base.encode16(sid),
                "encrypted_content" => Base.encode64(pl),
                "content_type" => 0,
                "hlc_wall" => ts
              }

              {[delta | acc], errs}

            {:error, _} ->
              {acc, errs + 1}
          end
        end)

      deltas = Enum.reverse(deltas)

      case Persistence.Sync.apply_deltas(tid, channel_id_bin, deltas) do
        {:ok, count} ->
          publish_sync_fanout(state, deltas)

          {wall, _counter} =
            Gateway.Native.hlc_tick(System.system_time(:millisecond), 0, state.user_id)

          reply_data = <<count::32-little, wall::64-little>>
          reply = <<@reply, ref::32-little, topic_id::16-little, @status_ok, reply_data::binary>>
          {:push, [{:binary, reply}], state}

        {:error, :too_large} ->
          reply =
            <<@reply, ref::32-little, topic_id::16-little, @status_error, "batch_too_large">>

          {:push, [{:binary, reply}], state}
      end
    else
      {:error, reason} ->
        reply =
          <<@reply, ref::32-little, topic_id::16-little, @status_error,
            to_string(reason)::binary>>

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

      with {:ok, channel_id_bin} <- channel_id_to_bin(info.channel_id) do
        tid_uuid = uuid_from_binary(state.tenant_id)
        uid_uuid = uuid_from_binary(state.user_id)
        did_uuid = uuid_from_binary(state.device_id)
        cid_uuid = uuid_from_binary(channel_id_bin)

        if tid_uuid && uid_uuid && did_uuid && cid_uuid do
          case Persistence.Sync.update_cursor(tid_uuid, uid_uuid, did_uuid, cid_uuid, hlc) do
            :ok -> :ok
            {:error, reason} -> Logger.warning("sync:cursor update failed: #{inspect(reason)}")
          end
        end
      end
    end

    {:ok, state}
  end

  defp dispatch(ref, topic_id, @ev_ch_create, payload, _info, state) do
    # payload: <<channel_type::8, name_len::16-little, name::binary>>
    <<ct::8, rest::binary>> = payload

    name =
      if byte_size(rest) >= 2 do
        <<nlen::16-little, remainder::binary>> = rest
        if byte_size(remainder) >= nlen, do: binary_part(remainder, 0, nlen), else: nil
      else
        nil
      end

    tid = state.tenant_id
    uid = state.user_id

    case Gateway.Native.validate_channel(tid, ct, name) do
      {:ok, _} ->
        channel_id = MercuryCore.Native.generate_channel_id()

        case Persistence.Members.add_member(tid, channel_id, uid) do
          :ok ->
            :ok

          {:error, reason} ->
            Logger.warning("ch:create membership insert failed: #{inspect(reason)}")
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

  defp dispatch(ref, topic_id, @ev_mls_members, _payload, info, state) do
    tid = state.tenant_id

    with {:ok, channel_id_bin} <- channel_id_to_bin(info.channel_id) do
      member_ids =
        case Persistence.Members.list_members(tid, channel_id_bin) do
          {:ok, ids} -> ids
          :empty -> []
          {:error, _} -> []
        end

      count = min(length(member_ids), 1000)
      ids = Enum.take(member_ids, count)
      packed = for uid <- ids, into: <<count::16-little>>, do: <<uid::binary-size(16)>>

      reply = <<@reply, ref::32-little, topic_id::16-little, @status_ok, packed::binary>>
      {:push, [{:binary, reply}], state}
    else
      {:error, reason} ->
        reply =
          <<@reply, ref::32-little, topic_id::16-little, @status_error,
            to_string(reason)::binary>>

        {:push, [{:binary, reply}], state}
    end
  end

  # mls:group_info — claim or query the MLS group creator for this channel
  # Response: <<1>> if caller became creator, <<0, creator_uid::16-bytes>> if someone else is creator
  defp dispatch(ref, topic_id, @ev_mls_group_info, _payload, info, state) do
    tid = state.tenant_id
    uid = state.user_id

    with {:ok, channel_id_bin} <- channel_id_to_bin(info.channel_id) do
      # Try to claim creator (NX = only if not set)
      Persistence.Cache.set_mls_creator(tid, channel_id_bin, uid)

      case Persistence.Cache.get_mls_creator(tid, channel_id_bin) do
        {:ok, creator_uid} when creator_uid == uid ->
          # We are the creator
          reply = <<@reply, ref::32-little, topic_id::16-little, @status_ok, 1::8>>
          {:push, [{:binary, reply}], state}

        {:ok, creator_uid} ->
          # Someone else is the creator
          reply =
            <<@reply, ref::32-little, topic_id::16-little, @status_ok, 0::8,
              creator_uid::binary-size(16)>>

          {:push, [{:binary, reply}], state}

        :miss ->
          # Cache unavailable — fallback: caller becomes creator
          reply = <<@reply, ref::32-little, topic_id::16-little, @status_ok, 1::8>>
          {:push, [{:binary, reply}], state}
      end
    else
      {:error, reason} ->
        reply =
          <<@reply, ref::32-little, topic_id::16-little, @status_error,
            to_string(reason)::binary>>

        {:push, [{:binary, reply}], state}
    end
  end

  # mls:cek — broadcast MLS-encrypted channel encryption key to the channel
  defp dispatch(ref, topic_id, @ev_mls_cek, payload, info, state) do
    broadcast_binary(info.pubsub, topic_id, @ev_mls_cek, payload)
    reply = <<@reply, ref::32-little, topic_id::16-little, @status_ok>>
    {:push, [{:binary, reply}], state}
  end

  defp dispatch(ref, topic_id, _event, _payload, _info, state) do
    reply = <<@reply, ref::32-little, topic_id::16-little, @status_error, "unknown_event">>
    {:push, [{:binary, reply}], state}
  end

  # ── Helpers ──

  defp allocate_topic_id(state) do
    tid = state.next_topic_id

    if tid > 0xFFFF do
      {:error, "too_many_topics"}
    else
      {:ok, tid, %{state | next_topic_id: tid + 1}}
    end
  end

  defp safe_nif_call(fun) do
    {:ok, fun.()}
  rescue
    e -> {:error, Exception.message(e)}
  end

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
    if Process.whereis(Persistence.Nats) do
      Persistence.Events.publish_message(tenant_id, channel_id, %{
        message_id: Base.encode16(msg.message_id),
        sender_id: Base.encode16(msg.sender_id),
        content_type: msg.content_type,
        created_at: msg.created_at
      })
    end

    if scylla_enabled?() do
      Task.Supervisor.start_child(Gateway.TaskSupervisor, fn ->
        case Persistence.Messages.write(tenant_id, channel_id, bucket, msg) do
          :ok ->
            # Invalidate cache only after successful write
            Persistence.Cache.invalidate_recent_messages(tenant_id, channel_id)
            publish_cache_invalidation(tenant_id, "recent", channel_id)

          {:error, reason} ->
            Logger.warning("ScyllaDB write failed: #{inspect(reason)}")
        end
      end)
    else
      # No ScyllaDB — still invalidate cache for consistency across nodes
      Persistence.Cache.invalidate_recent_messages(tenant_id, channel_id)
      publish_cache_invalidation(tenant_id, "recent", channel_id)
    end
  end

  defp scylla_enabled? do
    Application.get_env(:persistence, Persistence.Scylla, [])[:enabled] == true
  end

  defp persist_read_position(tenant_id, user_id, channel_id, message_id) do
    if scylla_enabled?() do
      with {:ok, channel_id_bin} <- channel_id_to_bin(channel_id) do
        Task.Supervisor.start_child(Gateway.TaskSupervisor, fn ->
          Persistence.ReadPositions.update(tenant_id, user_id, channel_id_bin, message_id)
        end)
      end
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

      case Gnat.pub(Persistence.Nats, "mercury.cache.invalidate", msg) do
        :ok -> :ok
        {:error, reason} -> Logger.warning("Cache invalidation NATS pub failed: #{inspect(reason)}")
      end
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

      case Gnat.pub(Persistence.Nats, topic, msg) do
        :ok -> :ok
        {:error, reason} -> Logger.warning("Sync fanout NATS pub failed: #{inspect(reason)}")
      end
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
    e in [DBConnection.ConnectionError, Postgrex.Error] ->
      Logger.warning("warm_user_cache DB error: #{inspect(e)}")
      :ok
  end

  @spec channel_id_to_bin(binary()) :: {:ok, binary()} | {:error, :invalid_channel_id}
  defp channel_id_to_bin(hex_channel_id) do
    case Base.decode16(hex_channel_id, case: :mixed) do
      {:ok, bin} when byte_size(bin) == 16 -> {:ok, bin}
      _ -> {:error, :invalid_channel_id}
    end
  end

  defp uuid_from_binary(<<a::32, b::16, c::16, d::16, e::48>>) do
    :io_lib.format("~8.16.0b-~4.16.0b-~4.16.0b-~4.16.0b-~12.16.0b", [a, b, c, d, e])
    |> IO.iodata_to_binary()
  end

  defp uuid_from_binary(_), do: nil
end
