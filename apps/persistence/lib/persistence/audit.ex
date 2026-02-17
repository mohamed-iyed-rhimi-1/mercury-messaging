defmodule Persistence.Audit do
  @moduledoc "Redpanda audit log — durable event log for compliance."

  @topic "mercury.audit.messages"

  @spec write_message_event(map()) :: :ok
  def write_message_event(event) do
    payload = Jason.encode!(event)
    # Partition by tenant_id for ordering within a tenant
    key = Map.get(event, :tenant_id, "default")
    partition = :erlang.phash2(key, partition_count())

    case :brod.produce_sync(:redpanda_client, @topic, partition, "", payload) do
      :ok -> :ok
      {:error, reason} -> log_error(reason)
    end
  end

  defp partition_count, do: Application.get_env(:persistence, __MODULE__, [])[:partitions] || 1

  defp log_error(reason) do
    require Logger
    Logger.warning("Redpanda audit write failed: #{inspect(reason)}")
    :ok
  end
end
