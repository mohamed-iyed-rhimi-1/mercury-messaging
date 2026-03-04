defmodule MercuryCore.Native do
  @moduledoc "Rustler NIF bridge to mercury-core/crdt/crypto."
  use Rustler,
    otp_app: :mercury_core,
    crate: "mercury-nif",
    path: "../../crates/mercury-nif",
    skip_compilation?: true,
    load_from: {:mercury_core, "priv/native/libmercury_nif"}

  @spec generate_message_id() :: binary()
  def generate_message_id, do: :erlang.nif_error(:nif_not_loaded)

  @spec generate_channel_id() :: binary()
  def generate_channel_id, do: :erlang.nif_error(:nif_not_loaded)

  @spec compute_time_bucket(non_neg_integer()) :: non_neg_integer()
  def compute_time_bucket(_timestamp_ms), do: :erlang.nif_error(:nif_not_loaded)

  @spec validate_message(binary(), binary(), binary(), binary(), non_neg_integer()) ::
          {:ok, :ok} | {:error, atom()}
  def validate_message(_tenant_id, _channel_id, _sender_id, _content, _content_type),
    do: :erlang.nif_error(:nif_not_loaded)

  @spec validate_channel(binary(), non_neg_integer(), String.t() | nil) ::
          {:ok, :ok} | {:error, atom()}
  def validate_channel(_tenant_id, _channel_type, _name),
    do: :erlang.nif_error(:nif_not_loaded)

  @spec hlc_tick(non_neg_integer(), non_neg_integer(), binary()) ::
          {non_neg_integer(), non_neg_integer()}
  def hlc_tick(_wall_clock_ms, _counter, _node_id), do: :erlang.nif_error(:nif_not_loaded)

  @spec hlc_merge(
          non_neg_integer(),
          non_neg_integer(),
          binary(),
          non_neg_integer(),
          non_neg_integer(),
          binary()
        ) :: {non_neg_integer(), non_neg_integer()}
  def hlc_merge(_lw, _lc, _ln, _rw, _rc, _rn), do: :erlang.nif_error(:nif_not_loaded)

  # MLS operations — state held in Rust ResourceArc

  @spec mls_create_identity(binary()) :: {:ok, reference()} | {:error, term()}
  def mls_create_identity(_identity), do: :erlang.nif_error(:nif_not_loaded)

  @spec mls_generate_key_package(reference()) :: {:ok, binary()} | {:error, term()}
  def mls_generate_key_package(_ref), do: :erlang.nif_error(:nif_not_loaded)

  @spec mls_create_group(reference(), binary()) :: :ok | {:error, term()}
  def mls_create_group(_ref, _group_id), do: :erlang.nif_error(:nif_not_loaded)

  @spec mls_add_member(reference(), binary(), binary()) ::
          {:ok, binary(), binary()} | {:error, term()}
  def mls_add_member(_ref, _group_id, _key_package), do: :erlang.nif_error(:nif_not_loaded)

  @spec mls_encrypt(reference(), binary(), binary()) :: {:ok, binary()} | {:error, term()}
  def mls_encrypt(_ref, _group_id, _plaintext), do: :erlang.nif_error(:nif_not_loaded)

  @spec mls_decrypt(reference(), binary(), binary()) :: {:ok, binary()} | {:error, term()}
  def mls_decrypt(_ref, _group_id, _ciphertext), do: :erlang.nif_error(:nif_not_loaded)

  @spec mls_process_welcome(reference(), binary()) :: {:ok, binary()} | {:error, term()}
  def mls_process_welcome(_ref, _welcome), do: :erlang.nif_error(:nif_not_loaded)

  @spec mls_process_commit(reference(), binary(), binary()) :: :ok | {:error, term()}
  def mls_process_commit(_ref, _group_id, _commit), do: :erlang.nif_error(:nif_not_loaded)

  # Cap'n Proto envelope
  @spec envelope_encode(binary(), binary(), binary(), binary(), non_neg_integer(), binary()) ::
          binary()
  def envelope_encode(_tenant_id, _channel_id, _sender_id, _message_id, _timestamp, _payload),
    do: :erlang.nif_error(:nif_not_loaded)

  @spec envelope_decode(binary()) ::
          {binary(), binary(), binary(), binary(), non_neg_integer(), binary()}
  def envelope_decode(_data), do: :erlang.nif_error(:nif_not_loaded)

  # Event encode/decode
  @spec typing_encode(binary()) :: binary()
  def typing_encode(_user_id), do: :erlang.nif_error(:nif_not_loaded)

  @doc "Decodes a typing event. Raises on invalid input — wrap with safe_nif_call."
  @spec typing_decode(binary()) :: binary()
  def typing_decode(_data), do: :erlang.nif_error(:nif_not_loaded)

  @spec read_receipt_encode(binary(), binary()) :: binary()
  def read_receipt_encode(_user_id, _message_id), do: :erlang.nif_error(:nif_not_loaded)

  @doc "Decodes a read receipt. Raises on invalid input — wrap with safe_nif_call."
  @spec read_receipt_decode(binary()) :: {binary(), binary()}
  def read_receipt_decode(_data), do: :erlang.nif_error(:nif_not_loaded)

  @spec mls_key_package_capnp_encode(binary()) :: binary()
  def mls_key_package_capnp_encode(_key_package), do: :erlang.nif_error(:nif_not_loaded)

  @doc "Decodes an MLS key package from Cap'n Proto. Raises on invalid input — wrap with safe_nif_call."
  @spec mls_key_package_capnp_decode(binary()) :: binary()
  def mls_key_package_capnp_decode(_data), do: :erlang.nif_error(:nif_not_loaded)

  @spec mls_key_package_list_encode([binary()]) :: binary()
  def mls_key_package_list_encode(_packages), do: :erlang.nif_error(:nif_not_loaded)

  @doc "Decodes an MLS key package list. Raises on invalid input — wrap with safe_nif_call."
  @spec mls_key_package_list_decode(binary()) :: [binary()]
  def mls_key_package_list_decode(_data), do: :erlang.nif_error(:nif_not_loaded)

  @spec mls_commit_capnp_encode(binary()) :: binary()
  def mls_commit_capnp_encode(_commit), do: :erlang.nif_error(:nif_not_loaded)

  @doc "Decodes an MLS commit from Cap'n Proto. Raises on invalid input — wrap with safe_nif_call."
  @spec mls_commit_capnp_decode(binary()) :: binary()
  def mls_commit_capnp_decode(_data), do: :erlang.nif_error(:nif_not_loaded)

  @spec mls_welcome_capnp_encode(binary(), binary()) :: binary()
  def mls_welcome_capnp_encode(_welcome, _user_id), do: :erlang.nif_error(:nif_not_loaded)

  @doc "Decodes an MLS welcome from Cap'n Proto. Raises on invalid input — wrap with safe_nif_call."
  @spec mls_welcome_capnp_decode(binary()) :: {binary(), binary()}
  def mls_welcome_capnp_decode(_data), do: :erlang.nif_error(:nif_not_loaded)
end
