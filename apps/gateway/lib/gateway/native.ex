defmodule Gateway.Native do
  @moduledoc "Backward-compat wrapper — delegates to MercuryCore.Native."

  defdelegate generate_message_id(), to: MercuryCore.Native
  defdelegate generate_channel_id(), to: MercuryCore.Native
  defdelegate compute_time_bucket(timestamp_ms), to: MercuryCore.Native
  defdelegate validate_message(tenant_id, channel_id, sender_id, content, content_type), to: MercuryCore.Native
  defdelegate validate_channel(tenant_id, channel_type, name), to: MercuryCore.Native
  defdelegate hlc_tick(wall_clock_ms, counter, node_id), to: MercuryCore.Native
  defdelegate hlc_merge(lw, lc, ln, rw, rc, rn), to: MercuryCore.Native
  defdelegate mls_create_identity(identity), to: MercuryCore.Native
  defdelegate mls_generate_key_package(ref), to: MercuryCore.Native
  defdelegate mls_create_group(ref, group_id), to: MercuryCore.Native
  defdelegate mls_add_member(ref, group_id, key_package), to: MercuryCore.Native
  defdelegate mls_encrypt(ref, group_id, plaintext), to: MercuryCore.Native
  defdelegate mls_decrypt(ref, group_id, ciphertext), to: MercuryCore.Native
  defdelegate mls_process_welcome(ref, welcome), to: MercuryCore.Native
  defdelegate mls_process_commit(ref, group_id, commit), to: MercuryCore.Native
  defdelegate envelope_encode(tenant_id, channel_id, sender_id, message_id, timestamp, payload), to: MercuryCore.Native
  defdelegate envelope_decode(data), to: MercuryCore.Native
  defdelegate typing_encode(user_id), to: MercuryCore.Native
  defdelegate typing_decode(data), to: MercuryCore.Native
  defdelegate read_receipt_encode(user_id, message_id), to: MercuryCore.Native
  defdelegate read_receipt_decode(data), to: MercuryCore.Native
  defdelegate mls_key_package_capnp_encode(key_package), to: MercuryCore.Native
  defdelegate mls_key_package_capnp_decode(data), to: MercuryCore.Native
  defdelegate mls_key_package_list_encode(packages), to: MercuryCore.Native
  defdelegate mls_key_package_list_decode(data), to: MercuryCore.Native
  defdelegate mls_commit_capnp_encode(commit), to: MercuryCore.Native
  defdelegate mls_commit_capnp_decode(data), to: MercuryCore.Native
  defdelegate mls_welcome_capnp_encode(welcome, user_id), to: MercuryCore.Native
  defdelegate mls_welcome_capnp_decode(data), to: MercuryCore.Native
end
