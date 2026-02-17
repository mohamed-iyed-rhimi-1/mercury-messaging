defmodule Persistence.Schema.SyncCursor do
  @moduledoc "Tracks per-device sync position for delta sync protocol."
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key false
  schema "sync_cursors" do
    field(:tenant_id, Ecto.UUID, primary_key: true)
    field(:user_id, Ecto.UUID, primary_key: true)
    field(:device_id, Ecto.UUID, primary_key: true)
    field(:channel_id, Ecto.UUID, primary_key: true)
    field(:last_hlc_wall, :integer, default: 0)
    field(:last_hlc_counter, :integer, default: 0)
    field(:last_hlc_node, :binary, default: <<0>>)
    field(:updated_at, :utc_datetime_usec)
  end

  @required ~w(tenant_id user_id device_id channel_id)a
  @optional ~w(last_hlc_wall last_hlc_counter last_hlc_node)a

  @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
  def changeset(cursor, attrs) do
    cursor
    |> cast(attrs, @required ++ @optional)
    |> validate_required(@required)
  end
end
