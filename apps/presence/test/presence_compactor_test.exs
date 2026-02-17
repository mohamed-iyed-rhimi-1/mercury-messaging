defmodule Presence.CompactorTest do
  use ExUnit.Case, async: true

  test "online if any device online" do
    presence = %{
      "user1" => %{
        metas: [
          %{status: :online, device_id: "d1"},
          %{status: :away, device_id: "d2"}
        ]
      }
    }

    result = Presence.Compactor.compact(presence)
    assert result["user1"].status == :online
    assert length(result["user1"].devices) == 2
  end

  test "away if all devices away" do
    presence = %{
      "user2" => %{
        metas: [
          %{status: :away, device_id: "d1"},
          %{status: :away, device_id: "d2"}
        ]
      }
    }

    result = Presence.Compactor.compact(presence)
    assert result["user2"].status == :away
  end

  test "empty presence" do
    assert Presence.Compactor.compact(%{}) == %{}
  end
end
