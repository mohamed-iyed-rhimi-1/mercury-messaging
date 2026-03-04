defmodule Persistence.Members do
  @moduledoc "Channel membership queries with Dragonfly cache-aside."
  import Ecto.Query
  require Logger

  alias Persistence.{Cache, Repo, Schema.ChannelMember}

  @spec member?(binary(), binary(), binary()) :: boolean() | {:error, term()}
  def member?(tenant_id, channel_id, user_id) do
    case list_members(tenant_id, channel_id) do
      {:ok, member_ids} -> user_id in member_ids
      :empty -> false
      {:error, _} = err -> err
    end
  end

  @spec list_members(binary(), binary()) :: {:ok, [binary()]} | :empty | {:error, term()}
  def list_members(tenant_id, channel_id) do
    case Cache.get_channel_members(tenant_id, channel_id) do
      {:ok, members} ->
        {:ok, members}

      :miss ->
        load_from_db(tenant_id, channel_id)
    end
  end

  @spec add_member(binary(), binary(), binary(), integer()) :: :ok | {:error, term()}
  def add_member(tenant_id, channel_id, user_id, role \\ 0) do
    attrs = %{
      tenant_id: to_uuid(tenant_id) || tenant_id,
      channel_id: to_uuid(channel_id) || channel_id,
      user_id: to_uuid(user_id) || user_id,
      role: role
    }

    case %ChannelMember{}
         |> ChannelMember.changeset(attrs)
         |> Repo.insert(on_conflict: :nothing) do
      {:ok, _} ->
        Cache.invalidate_channel_members(tenant_id, channel_id)
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec get_role(binary(), binary(), binary()) :: {:ok, integer()} | :not_found | {:error, term()}
  def get_role(tenant_id, channel_id, user_id) do
    tid = to_uuid(tenant_id)
    cid = to_uuid(channel_id)
    uid = to_uuid(user_id)

    if tid && cid && uid do
      case Repo.one(
             from(m in ChannelMember,
               where: m.tenant_id == ^tid and m.channel_id == ^cid and m.user_id == ^uid,
               select: m.role
             )
           ) do
        nil -> :not_found
        role -> {:ok, role}
      end
    else
      :not_found
    end
  rescue
    e ->
      Logger.warning("Members get_role DB error: #{inspect(e)}")
      {:error, :db_error}
  end

  @spec remove_member(binary(), binary(), binary()) :: :ok | {:error, term()}
  def remove_member(tenant_id, channel_id, user_id) do
    tid = to_uuid(tenant_id)
    cid = to_uuid(channel_id)
    uid = to_uuid(user_id)

    if tid && cid && uid do
      {count, _} =
        from(m in ChannelMember,
          where: m.tenant_id == ^tid and m.channel_id == ^cid and m.user_id == ^uid
        )
        |> Repo.delete_all()

      Cache.invalidate_channel_members(tenant_id, channel_id)

      if count > 0, do: :ok, else: {:error, :not_found}
    else
      {:error, :invalid_id}
    end
  rescue
    e ->
      Logger.warning("Members remove_member DB error: #{inspect(e)}")
      {:error, :db_error}
  end

  defp load_from_db(tenant_id, channel_id) do
    tid = to_uuid(tenant_id)
    cid = to_uuid(channel_id)

    if tid && cid do
      uuids =
        from(m in ChannelMember,
          where: m.tenant_id == ^tid and m.channel_id == ^cid,
          select: m.user_id
        )
        |> Repo.all()

      # Convert UUID strings back to raw 16-byte binaries for cache/comparison
      ids = uuids |> Enum.map(&to_raw/1) |> Enum.reject(&is_nil/1)

      case ids do
        [] ->
          :empty

        _ ->
          Cache.put_channel_members(tenant_id, channel_id, ids)
          {:ok, ids}
      end
    else
      :empty
    end
  rescue
    e ->
      Logger.warning("Members DB query failed: #{inspect(e)}")
      {:error, :db_unavailable}
  end

  # Convert 16-byte raw binary to UUID string for Ecto queries
  defp to_uuid(<<a::32, b::16, c::16, d::16, e::48>>) do
    :io_lib.format("~8.16.0b-~4.16.0b-~4.16.0b-~4.16.0b-~12.16.0b", [a, b, c, d, e])
    |> IO.iodata_to_binary()
  end

  defp to_uuid(str) when is_binary(str) and byte_size(str) == 36, do: str
  defp to_uuid(_), do: nil

  # Convert UUID string back to 16-byte raw binary
  defp to_raw(uuid) when is_binary(uuid) and byte_size(uuid) == 36 do
    case Ecto.UUID.dump(uuid) do
      {:ok, bin} -> bin
      :error -> nil
    end
  end

  defp to_raw(bin) when is_binary(bin) and byte_size(bin) == 16, do: bin
  defp to_raw(_), do: nil
end
