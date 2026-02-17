defmodule Persistence.Schema.Tenant do
  @moduledoc "Tenant schema — root entity for multi-tenancy."
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:tenant_id, :binary_id, autogenerate: true}

  schema "tenants" do
    field(:name, :string)
    field(:plan, :string, default: "free")
    field(:max_users, :integer, default: 1000)
    field(:max_channels, :integer, default: 100)
    field(:rate_limit_per_user, :integer, default: 100)
    timestamps(inserted_at: :created_at, type: :utc_datetime_usec)
  end

  @spec changeset(Ecto.Schema.t() | Ecto.Changeset.t(), map()) :: Ecto.Changeset.t()
  def changeset(tenant, attrs) do
    tenant
    |> cast(attrs, [:name, :plan, :max_users, :max_channels, :rate_limit_per_user])
    |> validate_required([:name])
    |> validate_length(:name, min: 1, max: 128)
    |> validate_inclusion(:plan, ["free", "pro", "enterprise"])
  end
end
