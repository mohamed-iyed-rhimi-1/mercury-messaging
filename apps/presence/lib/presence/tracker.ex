defmodule Presence.Tracker do
  @moduledoc "Phoenix.Presence tracker with per-device metadata."
  use Phoenix.Presence,
    otp_app: :presence,
    pubsub_server: Gateway.PubSub
end
