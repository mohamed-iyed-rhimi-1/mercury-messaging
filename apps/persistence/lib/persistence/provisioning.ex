defmodule Persistence.Provisioning do
  @moduledoc """
  Auto-provision tenant, user, and device rows on first connect.
  Uses INSERT ... ON CONFLICT DO NOTHING for idempotent upserts.
  Accepts raw 16-byte binaries (as stored in BinarySocket state).
  """

  alias Persistence.Repo
  import Ecto.Adapters.SQL, only: [query: 3]

  @spec ensure_device(binary(), binary(), binary()) :: :ok | {:error, term()}
  def ensure_device(tid, uid, did)
      when byte_size(tid) == 16 and byte_size(uid) == 16 and byte_size(did) == 16 do
    now = DateTime.utc_now()

    with {:ok, _} <-
           query(
             Repo,
             "INSERT INTO tenants (tenant_id, name, plan, max_users, max_channels, rate_limit_per_user, created_at, updated_at) VALUES ($1, 'default', 'free', 1000, 100, 100, $2, $2) ON CONFLICT (tenant_id) DO NOTHING",
             [tid, now]
           ),
         {:ok, _} <-
           query(
             Repo,
             "INSERT INTO users (tenant_id, user_id, display_name, created_at, updated_at) VALUES ($1, $2, 'user', $3, $3) ON CONFLICT (tenant_id, user_id) DO NOTHING",
             [tid, uid, now]
           ),
         {:ok, _} <-
           query(
             Repo,
             "INSERT INTO devices (tenant_id, device_id, user_id, device_name, platform, created_at, updated_at) VALUES ($1, $2, $3, 'browser', 'web', $4, $4) ON CONFLICT (tenant_id, device_id) DO NOTHING",
             [tid, did, uid, now]
           ) do
      :ok
    else
      {:error, _} = err -> err
    end
  end
end
