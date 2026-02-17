defmodule Gateway.ConnectionRegistry do
  @moduledoc "ETS-based registry: {tenant_id, user_id, device_id} → pid. O(1) lookup."
  use GenServer

  @table __MODULE__

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    _table = :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    {:ok, %{}}
  end

  @spec register(binary(), binary(), binary(), pid()) :: :ok
  def register(tenant_id, user_id, device_id, pid) do
    :ets.insert(@table, {{tenant_id, user_id, device_id}, pid})
    :ok
  end

  @spec unregister(binary(), binary(), binary()) :: :ok
  def unregister(tenant_id, user_id, device_id) do
    :ets.delete(@table, {tenant_id, user_id, device_id})
    :ok
  end

  @spec lookup(binary(), binary(), binary()) :: {:ok, pid()} | :not_found
  def lookup(tenant_id, user_id, device_id) do
    case :ets.lookup(@table, {tenant_id, user_id, device_id}) do
      [{_key, pid}] -> {:ok, pid}
      [] -> :not_found
    end
  end

  @spec user_devices(binary(), binary()) :: [pid()]
  def user_devices(tenant_id, user_id) do
    :ets.match_object(@table, {{tenant_id, user_id, :_}, :_})
    |> Enum.map(fn {_key, pid} -> pid end)
  end

  @spec count() :: non_neg_integer()
  def count do
    :ets.info(@table, :size)
  end
end
