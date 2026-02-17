defmodule Persistence.Schema.User do
  @moduledoc "User schema — belongs to a tenant."
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key false

  schema "users" do
    field(:user_id, :binary_id, primary_key: true, autogenerate: true)
    field(:tenant_id, :binary_id, primary_key: true)
    field(:display_name, :string)
    field(:avatar_url, :string)
    timestamps(inserted_at: :created_at, type: :utc_datetime_usec)
  end

  @spec changeset(Ecto.Schema.t() | Ecto.Changeset.t(), map()) :: Ecto.Changeset.t()
  def changeset(user, attrs) do
    user
    |> cast(attrs, [:tenant_id, :display_name, :avatar_url])
    |> validate_required([:tenant_id, :display_name])
    |> validate_length(:display_name, min: 1, max: 64)
  end
end
