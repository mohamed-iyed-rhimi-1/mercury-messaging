defmodule Persistence.KeyPackages do
  @moduledoc "KeyPackage CRUD — stores MLS key packages for devices."

  alias Persistence.{Repo, Schema.Device}
  import Ecto.Query

  @spec upload(Ecto.UUID.t(), Ecto.UUID.t(), binary()) :: :ok | {:error, :device_not_found}
  def upload(tenant_id, device_id, key_package_bytes) do
    Device
    |> where(tenant_id: ^tenant_id, device_id: ^device_id)
    |> Repo.update_all(set: [mls_key_package: key_package_bytes])
    |> case do
      {n, _} when n > 0 -> :ok
      {0, _} -> {:error, :device_not_found}
    end
  end

  @spec fetch(Ecto.UUID.t(), Ecto.UUID.t()) :: {:ok, [binary()]}
  def fetch(tenant_id, user_id) do
    packages =
      Device
      |> where(tenant_id: ^tenant_id, user_id: ^user_id)
      |> where([d], not is_nil(d.mls_key_package))
      |> select([d], d.mls_key_package)
      |> Repo.all()

    {:ok, packages}
  end

  @spec consume(Ecto.UUID.t(), Ecto.UUID.t()) :: {:ok, binary()} | {:error, :not_found}
  def consume(tenant_id, device_id) do
    Repo.transaction(fn ->
      case Repo.one(
             from(d in Device,
               where: d.tenant_id == ^tenant_id and d.device_id == ^device_id,
               where: not is_nil(d.mls_key_package),
               select: d.mls_key_package,
               lock: "FOR UPDATE"
             )
           ) do
        nil ->
          Repo.rollback(:not_found)

        kp ->
          Device
          |> where(tenant_id: ^tenant_id, device_id: ^device_id)
          |> Repo.update_all(set: [mls_key_package: nil])

          kp
      end
    end)
    |> case do
      {:ok, kp} -> {:ok, kp}
      {:error, :not_found} -> {:error, :not_found}
    end
  end
end
