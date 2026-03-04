defmodule Persistence.Audit do
  @moduledoc "Redpanda audit log — durable event log for compliance."
  require Logger

  @topic "mercury.audit.messages"
  @brod_timeout 5_000

  @spec write_message_event(map()) :: :ok | {:error, term()}
  def write_message_event(event) do
    payload = Jason.encode!(event)
    # Partition by tenant_id for ordering within a tenant
    key = Map.get(event, :tenant_id, "default")
    partition = :erlang.phash2(key, partition_count())

    case :brod.produce_sync(:redpanda_client, @topic, partition, "", payload, @brod_timeout) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning("Redpanda audit write failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp partition_count, do: Application.get_env(:persistence, __MODULE__, [])[:partitions] || 1
end
