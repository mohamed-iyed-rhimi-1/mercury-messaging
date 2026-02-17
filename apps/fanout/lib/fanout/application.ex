defmodule Fanout.Application do
  @moduledoc """
  Fan-out is handled directly by Phoenix PubSub in MessageChannel.broadcast!/3.
  No dedicated workers needed — PubSub already scales to 2M connections per node.
  Persistence is async via Task.start in persist_message/4.

  This OTP app is kept as a placeholder for future fan-out logic
  (e.g., push notifications to offline users, webhook delivery).
  """
  use Application

  @impl true
  def start(_type, _args) do
    Supervisor.start_link([], strategy: :one_for_one, name: Fanout.Supervisor)
  end
end
