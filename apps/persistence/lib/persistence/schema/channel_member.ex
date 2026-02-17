defmodule Persistence.Schema.ChannelMember do
  @moduledoc "Channel membership — links users to channels."
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key false

  schema "channel_members" do
    field(:tenant_id, :binary_id, primary_key: true)
    field(:channel_id, :binary_id, primary_key: true)
    field(:user_id, :binary_id, primary_key: true)
    field(:role, :integer, default: 0)
    field(:joined_at, :utc_datetime_usec, autogenerate: {DateTime, :utc_now, []})
  end

  @spec changeset(Ecto.Schema.t() | Ecto.Changeset.t(), map()) :: Ecto.Changeset.t()
  def changeset(member, attrs) do
    member
    |> cast(attrs, [:tenant_id, :channel_id, :user_id, :role])
    |> validate_required([:tenant_id, :channel_id, :user_id])
    |> validate_inclusion(:role, [0, 1, 2])
  end
end
