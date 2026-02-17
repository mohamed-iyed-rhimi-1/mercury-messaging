defmodule Gateway.SyncConsumer do
  @moduledoc """
  Subscribes to NATS sync subjects for connected users and pushes
  deltas to their other devices. One process per gateway node.
  """
  use GenServer
  require Logger

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Subscribe a user's devices to sync deltas."
  @spec subscribe(binary(), binary()) :: :ok
  def subscribe(tenant_id, user_id) do
    GenServer.cast(__MODULE__, {:subscribe, tenant_id, user_id})
  end

  @doc "Unsubscribe when user disconnects."
  @spec unsubscribe(binary(), binary()) :: :ok
  def unsubscribe(tenant_id, user_id) do
    GenServer.cast(__MODULE__, {:unsubscribe, tenant_id, user_id})
  end

  @impl true
  def init(_opts) do
    {:ok, %{subscriptions: %{}}}
  end

  @impl true
  def handle_cast({:subscribe, tenant_id, user_id}, state) do
    key = {tenant_id, user_id}

    if Map.has_key?(state.subscriptions, key) do
      {:noreply, state}
    else
      topic = "mercury.sync.#{Base.encode16(tenant_id)}.#{Base.encode16(user_id)}"

      case nats_subscribe(topic) do
        {:ok, sid} ->
          {:noreply, put_in(state.subscriptions[key], sid)}

        :error ->
          {:noreply, state}
      end
    end
  end

  @impl true
  def handle_cast({:unsubscribe, tenant_id, user_id}, state) do
    key = {tenant_id, user_id}

    case Map.pop(state.subscriptions, key) do
      {nil, _} ->
        {:noreply, state}

      {sid, subs} ->
        if Process.whereis(Persistence.Nats), do: _ = Gnat.unsub(Persistence.Nats, sid)
        {:noreply, %{state | subscriptions: subs}}
    end
  end

  @impl true
  def handle_info({:msg, %{body: body}}, state) do
    _ =
      case Jason.decode(body) do
        {:ok, %{"device_id" => origin_device, "deltas" => deltas}} ->
          Phoenix.PubSub.broadcast(
            Gateway.PubSub,
            "sync:fanout",
            {:sync_deltas, origin_device, deltas}
          )

        _ ->
          Logger.debug("SyncConsumer: ignoring malformed message")
      end

    {:noreply, state}
  end

  @impl true
  def handle_info(_msg, state), do: {:noreply, state}

  defp nats_subscribe(topic) do
    if Process.whereis(Persistence.Nats) do
      case Gnat.sub(Persistence.Nats, self(), topic) do
        {:ok, sid} -> {:ok, sid}
        _ -> :error
      end
    else
      :error
    end
  end
end
