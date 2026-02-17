defmodule Persistence.Members do
  @moduledoc "Channel membership queries with Dragonfly cache-aside."
  import Ecto.Query
  require Logger

  alias Persistence.{Cache, Repo, Schema.ChannelMember}

  @spec member?(binary(), binary(), binary()) :: boolean()
  def member?(tenant_id, channel_id, user_id) do
    case list_members(tenant_id, channel_id) do
      {:ok, member_ids} -> user_id in member_ids
      :empty -> true
    end
  end

  @spec list_members(binary(), binary()) :: {:ok, [binary()]} | :empty
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
      tenant_id: tenant_id,
      channel_id: channel_id,
      user_id: user_id,
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

  @spec remove_member(binary(), binary(), binary()) :: :ok
  def remove_member(tenant_id, channel_id, user_id) do
    from(m in ChannelMember,
      where:
        m.tenant_id == ^tenant_id and
          m.channel_id == ^channel_id and
          m.user_id == ^user_id
    )
    |> Repo.delete_all()

    Cache.invalidate_channel_members(tenant_id, channel_id)
    :ok
  end

  defp load_from_db(tenant_id, channel_id) do
    members =
      from(m in ChannelMember,
        where: m.tenant_id == ^tenant_id and m.channel_id == ^channel_id,
        select: m.user_id
      )
      |> Repo.all()

    case members do
      [] ->
        :empty

      ids ->
        hex_ids = Enum.map(ids, &Base.encode16/1)
        Cache.put_channel_members(tenant_id, channel_id, hex_ids)
        {:ok, hex_ids}
    end
  rescue
    e ->
      Logger.warning("Members DB query failed: #{inspect(e)}")
      :empty
  end
end
