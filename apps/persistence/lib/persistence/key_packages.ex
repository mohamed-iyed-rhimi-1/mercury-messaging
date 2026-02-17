defmodule Persistence.KeyPackages do
  @moduledoc "KeyPackage CRUD — stores MLS key packages for devices."

  alias Persistence.{Repo, Schema.Device}
  import Ecto.Query

  @spec upload(Ecto.UUID.t(), Ecto.UUID.t(), binary()) :: :ok
  def upload(tenant_id, device_id, key_package_bytes) do
    Device
    |> where(tenant_id: ^tenant_id, device_id: ^device_id)
    |> Repo.update_all(set: [mls_key_package: key_package_bytes])
    |> then(fn {_, _} -> :ok end)
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
    case Repo.one(
           from(d in Device,
             where: d.tenant_id == ^tenant_id and d.device_id == ^device_id,
             where: not is_nil(d.mls_key_package),
             select: d.mls_key_package
           )
         ) do
      nil ->
        {:error, :not_found}

      kp ->
        Device
        |> where(tenant_id: ^tenant_id, device_id: ^device_id)
        |> Repo.update_all(set: [mls_key_package: nil])

        {:ok, kp}
    end
  end
end
