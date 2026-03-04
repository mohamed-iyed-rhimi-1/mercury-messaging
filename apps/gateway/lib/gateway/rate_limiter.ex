defmodule Gateway.RateLimiter do
  @moduledoc "Per-user rate limiter backed by Dragonfly (shared across replicas)."

  @default_rate 100

  @spec allow?(binary(), binary()) :: boolean()
  def allow?(tenant_id, user_id) do
    rate = Application.get_env(:gateway, __MODULE__)[:default_rate] || @default_rate

    case Persistence.Cache.rate_check(tenant_id, user_id, rate) do
      :allow -> true
      :deny -> false
    end
  end
end
