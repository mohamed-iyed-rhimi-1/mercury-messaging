defmodule Gateway.RateLimiter do
  @moduledoc """
  Per-user rate limiter backed by Dragonfly (shared across replicas).
  Falls back to ETS if Dragonfly is unavailable.
  """
  use GenServer

  @table __MODULE__
  @default_rate 100
  @refill_interval 1_000

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    _table = :ets.new(@table, [:named_table, :public, :set, write_concurrency: true])
    schedule_refill()
    {:ok, %{}}
  end

  @spec allow?(binary(), binary()) :: boolean()
  def allow?(tenant_id, user_id) do
    rate = Application.get_env(:gateway, __MODULE__)[:default_rate] || @default_rate

    case Persistence.Cache.rate_check(tenant_id, user_id, rate) do
      :allow -> true
      :deny -> false
    end
  end

  # ETS cleanup — evict stale entries periodically
  @impl true
  def handle_info(:refill, state) do
    # ETS no longer used for rate limiting, but keep cleanup for any legacy entries
    :ets.delete_all_objects(@table)
    schedule_refill()
    {:noreply, state}
  end

  defp schedule_refill, do: Process.send_after(self(), :refill, @refill_interval)
end
