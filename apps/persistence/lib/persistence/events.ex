defmodule Persistence.Events do
  @moduledoc "NATS JetStream event publishing for the message pipeline."

  @spec publish_message(binary(), binary(), map()) :: :ok
  def publish_message(tenant_id, channel_id, msg) do
    subject = "mercury.#{Base.encode16(tenant_id)}.messages.#{Base.encode16(channel_id)}"
    payload = Jason.encode!(msg)
    :ok = Gnat.pub(Persistence.Nats, subject, payload)
  end

  @spec subscribe_messages(binary(), binary()) :: {:ok, non_neg_integer()}
  def subscribe_messages(tenant_id, channel_id) do
    subject = "mercury.#{Base.encode16(tenant_id)}.messages.#{Base.encode16(channel_id)}"
    Gnat.sub(Persistence.Nats, self(), subject)
  end
end
