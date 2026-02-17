defmodule Presence.DistributedTest do
  @moduledoc """
  Tests that Phoenix.Presence correctly merges state across multiple tracker
  instances sharing the same PubSub. This validates the CRDT merge behavior
  that powers multi-node presence in production (where each node runs its
  own Tracker process connected via distributed PubSub).
  """
  use ExUnit.Case, async: false

  @topic "presence:distributed_test"

  test "presence state merges across multiple trackers via shared PubSub" do
    # Presence.Tracker is already started by the app supervisor on Gateway.PubSub.
    # Track 3 users from different "simulated origins"
    pid1 = spawn(fn -> Process.sleep(:infinity) end)
    pid2 = spawn(fn -> Process.sleep(:infinity) end)
    pid3 = spawn(fn -> Process.sleep(:infinity) end)

    {:ok, _} =
      Presence.Tracker.track(pid1, @topic, "user:alice", %{
        status: :online,
        device_id: "phone"
      })

    {:ok, _} =
      Presence.Tracker.track(pid2, @topic, "user:bob", %{
        status: :away,
        device_id: "laptop"
      })

    {:ok, _} =
      Presence.Tracker.track(pid3, @topic, "user:alice", %{
        status: :away,
        device_id: "desktop"
      })

    # Allow presence to propagate
    Process.sleep(100)

    # List should show both users, alice with 2 devices
    presences = Presence.Tracker.list(@topic)

    assert Map.has_key?(presences, "user:alice")
    assert Map.has_key?(presences, "user:bob")

    alice_metas = presences["user:alice"].metas
    assert length(alice_metas) == 2

    devices = Enum.map(alice_metas, & &1.device_id) |> Enum.sort()
    assert devices == ["desktop", "phone"]

    # Verify compactor aggregates correctly
    compacted = Presence.Compactor.compact(presences)
    assert compacted["user:alice"].status == :online
    assert compacted["user:bob"].status == :away
    assert length(compacted["user:alice"].devices) == 2

    # Simulate device disconnect — kill pid1 (alice's phone)
    Process.exit(pid1, :kill)
    Process.sleep(200)

    presences_after = Presence.Tracker.list(@topic)
    alice_after = presences_after["user:alice"].metas
    assert length(alice_after) == 1
    assert hd(alice_after).device_id == "desktop"

    # Compactor should now show alice as away (only desktop, which is away)
    compacted_after = Presence.Compactor.compact(presences_after)
    assert compacted_after["user:alice"].status == :away

    # Cleanup
    Process.exit(pid2, :kill)
    Process.exit(pid3, :kill)
  end

  test "presence diff broadcasts join and leave events" do
    topic = "presence:diff_test_#{System.unique_integer([:positive])}"
    Phoenix.PubSub.subscribe(Gateway.PubSub, topic)
    Process.sleep(50)

    pid = spawn(fn -> Process.sleep(:infinity) end)

    {:ok, _} =
      Presence.Tracker.track(pid, topic, "user:carol", %{
        status: :online,
        device_id: "tablet"
      })

    # Should receive a presence_diff with carol joining
    assert_receive %Phoenix.Socket.Broadcast{
                     event: "presence_diff",
                     payload: %{joins: joins}
                   },
                   1_000

    assert Map.has_key?(joins, "user:carol")

    # Kill the process — should get a leave diff
    Process.exit(pid, :kill)

    assert_receive %Phoenix.Socket.Broadcast{
                     event: "presence_diff",
                     payload: %{leaves: leaves}
                   },
                   1_000

    assert Map.has_key?(leaves, "user:carol")

    Phoenix.PubSub.unsubscribe(Gateway.PubSub, topic)
  end
end
