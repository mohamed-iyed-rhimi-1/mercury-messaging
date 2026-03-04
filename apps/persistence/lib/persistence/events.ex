defmodule Persistence.Events do
  @moduledoc "NATS JetStream event publishing for the message pipeline."
  require Logger

  @spec publish_message(binary(), binary(), map()) :: :ok | {:error, term()}
  def publish_message(tenant_id, channel_id, msg) do
    subject = "mercury.#{Base.encode16(tenant_id)}.messages.#{Base.encode16(channel_id)}"
    payload = Jason.encode!(msg)

    case Gnat.pub(Persistence.Nats, subject, payload) do
      :ok -> :ok
      {:error, reason} ->
        Logger.warning("NATS publish failed on #{subject}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @spec subscribe_messages(binary(), binary()) :: {:ok, non_neg_integer()}
  def subscribe_messages(tenant_id, channel_id) do
    subject = "mercury.#{Base.encode16(tenant_id)}.messages.#{Base.encode16(channel_id)}"
    Gnat.sub(Persistence.Nats, self(), subject)
  end
end
