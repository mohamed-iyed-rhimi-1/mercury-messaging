defmodule Persistence.Schema.Device do
  @moduledoc "Device schema — multi-device support with MLS key packages."
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key false
  schema "devices" do
    field(:device_id, Ecto.UUID, autogenerate: true, primary_key: true)
    field(:tenant_id, Ecto.UUID, primary_key: true)
    field(:user_id, Ecto.UUID)
    field(:device_name, :string)
    field(:platform, :string)
    field(:push_token, :string)
    field(:mls_key_package, :binary)
    field(:last_seen_at, :utc_datetime_usec)

    timestamps(type: :utc_datetime_usec, inserted_at: :created_at)
  end

  @required ~w(tenant_id user_id device_name platform)a
  @optional ~w(push_token mls_key_package last_seen_at)a
  @platforms ~w(ios android web desktop)

  @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
  def changeset(device, attrs) do
    device
    |> cast(attrs, @required ++ @optional)
    |> validate_required(@required)
    |> validate_length(:device_name, min: 1, max: 128)
    |> validate_inclusion(:platform, @platforms)
  end
end
