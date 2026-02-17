defmodule Gateway.RateLimiterTest do
  use ExUnit.Case, async: false

  @tid <<1::128>>
  @uid <<50::128>>

  test "allows initial requests" do
    assert Gateway.RateLimiter.allow?(@tid, @uid)
  end

  test "throttles after burst" do
    uid = :crypto.strong_rand_bytes(16)

    # Exhaust the burst (150 default)
    results =
      for _ <- 1..200 do
        Gateway.RateLimiter.allow?(@tid, uid)
      end

    allowed = Enum.count(results, & &1)
    denied = Enum.count(results, &(!&1))
    assert allowed == 150
    assert denied == 50
  end
end
