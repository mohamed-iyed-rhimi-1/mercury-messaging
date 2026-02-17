defmodule Persistence.Consumer do
  @moduledoc "NATS consumer — handles audit log and cache invalidation events."
  use GenServer
  require Logger

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    if nats_enabled?() do
      {:ok, _} = Gnat.sub(Persistence.Nats, self(), "mercury.*.messages.*")
      {:ok, _} = Gnat.sub(Persistence.Nats, self(), "mercury.cache.invalidate")
      {:ok, %{count: 0}}
    else
      {:ok, %{count: 0}}
    end
  end

  @impl true
  def handle_info({:msg, %{body: body, topic: "mercury.cache.invalidate"}}, state) do
    handle_cache_invalidation(body)
    {:noreply, state}
  end

  def handle_info({:msg, %{body: body, topic: topic}}, state) do
    if audit_enabled?() do
      event = %{topic: topic, payload: body, received_at: System.os_time(:millisecond)}
      Persistence.Audit.write_message_event(event)
    end

    {:noreply, %{state | count: state.count + 1}}
  end

  @impl true
  def handle_info(_msg, state), do: {:noreply, state}

  defp handle_cache_invalidation(body) do
    case Jason.decode(body) do
      {:ok, %{"type" => "recent", "tenant_id" => tid_hex, "target_id" => cid_hex}} ->
        with {:ok, tid} <- Base.decode16(tid_hex, case: :mixed),
             {:ok, cid} <- Base.decode16(cid_hex, case: :mixed) do
          Persistence.Cache.invalidate_recent_messages(tid, cid)
        end

      {:ok, %{"type" => "user", "tenant_id" => tid_hex, "target_id" => uid_hex}} ->
        with {:ok, tid} <- Base.decode16(tid_hex, case: :mixed),
             {:ok, uid} <- Base.decode16(uid_hex, case: :mixed) do
          Persistence.Cache.invalidate_user(tid, uid)
        end

      {:ok, %{"type" => "members", "tenant_id" => tid_hex, "target_id" => cid_hex}} ->
        with {:ok, tid} <- Base.decode16(tid_hex, case: :mixed),
             {:ok, cid} <- Base.decode16(cid_hex, case: :mixed) do
          Persistence.Cache.invalidate_channel_members(tid, cid)
        end

      _ ->
        Logger.warning("Unknown cache invalidation event: #{body}")
    end
  rescue
    e -> Logger.warning("Cache invalidation failed: #{inspect(e)}")
  end

  defp nats_enabled?,
    do: Application.get_env(:persistence, Persistence.Events, [])[:enabled] == true

  defp audit_enabled?,
    do: Application.get_env(:persistence, Persistence.Audit, [])[:enabled] == true
end
