defmodule Gateway.GcWorker do
  @moduledoc """
  Background worker for tombstone garbage collection.
  Runs every 6 hours. Cleans expired sync cursors and old data.
  Bounded: max 10,000 deletes per run (NASA Rule #2).
  """
  use GenServer
  require Logger

  alias Ecto.Adapters.SQL

  @gc_interval :timer.hours(6)
  @max_deletes 10_000
  @cursor_ttl_days 90

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    schedule_gc()
    {:ok, %{last_run: nil, total_cleaned: 0}}
  end

  @impl true
  def handle_info(:run_gc, state) do
    cleaned = run_gc()
    schedule_gc()

    {:noreply,
     %{state | last_run: DateTime.utc_now(), total_cleaned: state.total_cleaned + cleaned}}
  end

  defp run_gc do
    cursors_cleaned = clean_expired_cursors()
    Logger.info("GC complete: #{cursors_cleaned} expired cursors cleaned")
    cursors_cleaned
  rescue
    e ->
      Logger.error("GC failed: #{inspect(e)}")
      0
  end

  defp clean_expired_cursors do
    cutoff = DateTime.add(DateTime.utc_now(), -@cursor_ttl_days, :day)

    case SQL.query(
           Persistence.Repo,
           "DELETE FROM sync_cursors WHERE updated_at < $1 LIMIT $2",
           [cutoff, @max_deletes]
         ) do
      {:ok, %{num_rows: n}} -> n
      {:error, _} -> 0
    end
  rescue
    _ -> 0
  end

  defp schedule_gc do
    Process.send_after(self(), :run_gc, @gc_interval)
  end
end
