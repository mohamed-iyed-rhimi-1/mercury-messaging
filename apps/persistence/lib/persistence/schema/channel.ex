defmodule Persistence.Schema.Channel do
  @moduledoc "Channel schema — DM (0), Group (1), or Broadcast (2)."
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key false

  schema "channels" do
    field(:channel_id, :binary_id, primary_key: true, autogenerate: true)
    field(:tenant_id, :binary_id, primary_key: true)
    field(:channel_type, :integer)
    field(:name, :string)
    field(:created_by, :binary_id)
    timestamps(inserted_at: :created_at, type: :utc_datetime_usec)
  end

  @spec changeset(Ecto.Schema.t() | Ecto.Changeset.t(), map()) :: Ecto.Changeset.t()
  def changeset(channel, attrs) do
    channel
    |> cast(attrs, [:tenant_id, :channel_type, :name, :created_by])
    |> validate_required([:tenant_id, :channel_type, :created_by])
    |> validate_inclusion(:channel_type, [0, 1, 2])
    |> validate_length(:name, max: 128)
  end
end
