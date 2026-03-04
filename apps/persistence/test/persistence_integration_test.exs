defmodule Persistence.IntegrationTest do
  @moduledoc """
  Integration tests requiring running Docker services.
  Run with: mix test apps/persistence/test/persistence_integration_test.exs --include integration
  """
  use ExUnit.Case, async: false

  alias Persistence.Schema.{Device, Tenant, User}
  alias Persistence.Schema.SyncCursor

  @moduletag :integration

  @tenant_id :crypto.strong_rand_bytes(16)
  @channel_id :crypto.strong_rand_bytes(16)
  @sender_id :crypto.strong_rand_bytes(16)

  setup_all do
    # Stop any existing named processes from previous runs
    for name <- [Persistence.Scylla, Persistence.Redis, Persistence.Nats] do
      case Process.whereis(name) do
        nil ->
          :ok

        pid ->
          try do
            GenServer.stop(pid, :normal, 1000)
          rescue
            _ -> :ok
          end
      end
    end

    Process.sleep(100)

    {:ok, _} =
      Xandra.Cluster.start_link(
        name: Persistence.Scylla,
        nodes: ["localhost:9042"],
        keyspace: "mercury",
        pool_size: 2
      )

    # Wait for pool to be ready
    Process.sleep(2000)

    {:ok, _} =
      Redix.start_link(
        host: "localhost",
        port: 6380,
        password: "mercury",
        name: Persistence.Redis
      )

    {:ok, _} = Gnat.start_link(%{host: "127.0.0.1", port: 4222}, name: Persistence.Nats)

    # Wait for Xandra cluster pool to establish connections
    Process.sleep(1000)

    :ok
  end

  describe "ScyllaDB messages" do
    test "write and read message" do
      bucket = MercuryCore.Native.compute_time_bucket(System.os_time(:millisecond))
      msg_id = MercuryCore.Native.generate_message_id()

      msg = %{
        message_id: msg_id,
        sender_id: @sender_id,
        encrypted_content: "hello world",
        content_type: 0,
        reply_to: nil,
        created_at: System.os_time(:millisecond)
      }

      assert :ok = Persistence.Messages.write(@tenant_id, @channel_id, bucket, msg)

      assert {:ok, [read_msg | _]} =
               Persistence.Messages.read(@tenant_id, @channel_id, bucket, 10)

      assert read_msg.encrypted_content == "hello world"
      assert read_msg.content_type == 0
    end

    test "tenant isolation" do
      bucket = MercuryCore.Native.compute_time_bucket(System.os_time(:millisecond))
      other_tenant = :crypto.strong_rand_bytes(16)

      msg = %{
        message_id: MercuryCore.Native.generate_message_id(),
        sender_id: @sender_id,
        encrypted_content: "secret",
        content_type: 0,
        reply_to: nil,
        created_at: System.os_time(:millisecond)
      }

      :ok = Persistence.Messages.write(@tenant_id, @channel_id, bucket, msg)
      assert {:ok, []} = Persistence.Messages.read(other_tenant, @channel_id, bucket, 10)
    end

    test "messages ordered by message_id DESC" do
      bucket = MercuryCore.Native.compute_time_bucket(System.os_time(:millisecond))
      channel = :crypto.strong_rand_bytes(16)

      ids =
        for i <- 1..5 do
          Process.sleep(1)
          id = MercuryCore.Native.generate_message_id()

          msg = %{
            message_id: id,
            sender_id: @sender_id,
            encrypted_content: "msg #{i}",
            content_type: 0,
            reply_to: nil,
            created_at: System.os_time(:millisecond)
          }

          :ok = Persistence.Messages.write(@tenant_id, channel, bucket, msg)
          id
        end

      {:ok, read_msgs} = Persistence.Messages.read(@tenant_id, channel, bucket, 10)
      read_ids = Enum.map(read_msgs, & &1.message_id)
      assert read_ids == Enum.reverse(ids)
    end
  end

  describe "Dragonfly cache" do
    test "user cache roundtrip" do
      tid = :crypto.strong_rand_bytes(16)
      uid = :crypto.strong_rand_bytes(16)

      assert :miss = Persistence.Cache.get_user(tid, uid)
      :ok = Persistence.Cache.put_user(tid, uid, %{"name" => "Alice"})
      assert {:ok, %{"name" => "Alice"}} = Persistence.Cache.get_user(tid, uid)
      :ok = Persistence.Cache.invalidate_user(tid, uid)
      assert :miss = Persistence.Cache.get_user(tid, uid)
    end

    test "channel members cache" do
      tid = :crypto.strong_rand_bytes(16)
      cid = :crypto.strong_rand_bytes(16)

      assert :miss = Persistence.Cache.get_channel_members(tid, cid)
      :ok = Persistence.Cache.put_channel_members(tid, cid, ["user1", "user2", "user3"])
      {:ok, members} = Persistence.Cache.get_channel_members(tid, cid)
      assert Enum.sort(members) == ["user1", "user2", "user3"]
    end
  end

  describe "NATS events" do
    test "publish and subscribe roundtrip" do
      tid = :crypto.strong_rand_bytes(16)
      cid = :crypto.strong_rand_bytes(16)

      {:ok, _sid} = Persistence.Events.subscribe_messages(tid, cid)

      msg = %{id: "test123", content: "hello"}
      :ok = Persistence.Events.publish_message(tid, cid, msg)

      assert_receive {:msg, %{body: body}}, 2_000
      decoded = Jason.decode!(body)
      assert decoded["id"] == "test123"
      assert decoded["content"] == "hello"
    end
  end

  describe "PostgreSQL via Ecto" do
    test "tenant CRUD" do
      {:ok, tenant} =
        %Tenant{}
        |> Tenant.changeset(%{name: "Test Corp"})
        |> Persistence.Repo.insert()

      assert tenant.name == "Test Corp"
      assert tenant.plan == "free"

      found = Persistence.Repo.get(Tenant, tenant.tenant_id)
      assert found.name == "Test Corp"
    end

    test "user CRUD with tenant" do
      {:ok, tenant} =
        %Tenant{}
        |> Tenant.changeset(%{name: "User Test Corp"})
        |> Persistence.Repo.insert()

      {:ok, user} =
        %User{}
        |> User.changeset(%{
          tenant_id: tenant.tenant_id,
          display_name: "Alice"
        })
        |> Persistence.Repo.insert()

      assert user.display_name == "Alice"

      found =
        Persistence.Repo.get_by(User,
          tenant_id: tenant.tenant_id,
          user_id: user.user_id
        )

      assert found.display_name == "Alice"
    end
  end

  describe "MLS NIF roundtrip" do
    test "full lifecycle: identity → group → add member → encrypt → decrypt" do
      # Alice creates identity and group
      {:ok, alice_ref} = MercuryCore.Native.mls_create_identity("alice-device-1")
      {:ok, alice_kp} = MercuryCore.Native.mls_generate_key_package(alice_ref)
      assert is_binary(alice_kp) and byte_size(alice_kp) > 0

      group_id = "test-group-#{System.unique_integer([:positive])}"
      :ok = MercuryCore.Native.mls_create_group(alice_ref, group_id)

      # Bob creates identity and key package
      {:ok, bob_ref} = MercuryCore.Native.mls_create_identity("bob-device-1")
      {:ok, bob_kp} = MercuryCore.Native.mls_generate_key_package(bob_ref)

      # Alice adds Bob using his key package
      {:ok, commit, welcome} = MercuryCore.Native.mls_add_member(alice_ref, group_id, bob_kp)
      assert byte_size(commit) > 0
      assert byte_size(welcome) > 0

      # Bob processes welcome to join the group
      {:ok, joined_group_id} = MercuryCore.Native.mls_process_welcome(bob_ref, welcome)
      assert is_binary(joined_group_id)

      # Alice encrypts a message
      plaintext = "hello from alice"
      {:ok, ciphertext} = MercuryCore.Native.mls_encrypt(alice_ref, group_id, plaintext)
      assert ciphertext != plaintext

      # Bob decrypts the message
      {:ok, decrypted} = MercuryCore.Native.mls_decrypt(bob_ref, joined_group_id, ciphertext)
      assert decrypted == plaintext
    end

    test "process_commit syncs group state" do
      {:ok, alice_ref} = MercuryCore.Native.mls_create_identity("alice-commit-test")
      group_id = "commit-group-#{System.unique_integer([:positive])}"
      :ok = MercuryCore.Native.mls_create_group(alice_ref, group_id)

      {:ok, bob_ref} = MercuryCore.Native.mls_create_identity("bob-commit-test")
      {:ok, bob_kp} = MercuryCore.Native.mls_generate_key_package(bob_ref)

      # Charlie will process the commit as an existing member
      {:ok, charlie_ref} = MercuryCore.Native.mls_create_identity("charlie-commit-test")
      {:ok, charlie_kp} = MercuryCore.Native.mls_generate_key_package(charlie_ref)

      # Add Charlie first
      {:ok, _commit1, welcome1} = MercuryCore.Native.mls_add_member(alice_ref, group_id, charlie_kp)
      {:ok, charlie_gid} = MercuryCore.Native.mls_process_welcome(charlie_ref, welcome1)

      # Alice adds Bob — Charlie must process the commit
      {:ok, commit2, _welcome2} = MercuryCore.Native.mls_add_member(alice_ref, group_id, bob_kp)
      :ok = MercuryCore.Native.mls_process_commit(charlie_ref, charlie_gid, commit2)
    end
  end

  describe "KeyPackage PostgreSQL CRUD" do
    setup do
      {:ok, tenant} =
        %Tenant{}
        |> Tenant.changeset(%{name: "KP Test Corp #{System.unique_integer([:positive])}"})
        |> Persistence.Repo.insert()

      {:ok, user} =
        %User{}
        |> User.changeset(%{tenant_id: tenant.tenant_id, display_name: "KP User"})
        |> Persistence.Repo.insert()

      {:ok, device} =
        %Device{}
        |> Device.changeset(%{
          tenant_id: tenant.tenant_id,
          user_id: user.user_id,
          device_name: "iPhone",
          platform: "ios"
        })
        |> Persistence.Repo.insert()

      %{tenant_id: tenant.tenant_id, user_id: user.user_id, device_id: device.device_id}
    end

    test "upload, fetch, and consume key package", ctx do
      # Initially empty
      {:ok, []} = Persistence.KeyPackages.fetch(ctx.tenant_id, ctx.user_id)

      # Upload a key package
      kp_bytes = :crypto.strong_rand_bytes(256)
      :ok = Persistence.KeyPackages.upload(ctx.tenant_id, ctx.device_id, kp_bytes)

      # Fetch returns it
      {:ok, [fetched]} = Persistence.KeyPackages.fetch(ctx.tenant_id, ctx.user_id)
      assert fetched == kp_bytes

      # Consume returns and removes it
      {:ok, consumed} = Persistence.KeyPackages.consume(ctx.tenant_id, ctx.device_id)
      assert consumed == kp_bytes

      # Now empty again
      {:ok, []} = Persistence.KeyPackages.fetch(ctx.tenant_id, ctx.user_id)
      {:error, :not_found} = Persistence.KeyPackages.consume(ctx.tenant_id, ctx.device_id)
    end

    test "fetch returns packages from multiple devices", ctx do
      # Create a second device for the same user
      {:ok, device2} =
        %Device{}
        |> Device.changeset(%{
          tenant_id: ctx.tenant_id,
          user_id: ctx.user_id,
          device_name: "Android",
          platform: "android"
        })
        |> Persistence.Repo.insert()

      kp1 = :crypto.strong_rand_bytes(128)
      kp2 = :crypto.strong_rand_bytes(128)
      :ok = Persistence.KeyPackages.upload(ctx.tenant_id, ctx.device_id, kp1)
      :ok = Persistence.KeyPackages.upload(ctx.tenant_id, device2.device_id, kp2)

      {:ok, packages} = Persistence.KeyPackages.fetch(ctx.tenant_id, ctx.user_id)
      assert length(packages) == 2
      assert Enum.sort(packages) == Enum.sort([kp1, kp2])
    end
  end

  describe "Delta sync" do
    test "get_deltas returns messages after given timestamp" do
      channel = :crypto.strong_rand_bytes(16)
      ts_before = System.system_time(:millisecond)
      Process.sleep(10)

      # Write 3 messages
      for i <- 1..3 do
        ts = System.system_time(:millisecond)
        bucket = MercuryCore.Native.compute_time_bucket(ts)

        :ok =
          Persistence.Messages.write(@tenant_id, channel, bucket, %{
            message_id: MercuryCore.Native.generate_message_id(),
            sender_id: @sender_id,
            encrypted_content: "sync msg #{i}",
            content_type: 0,
            reply_to: nil,
            created_at: ts
          })

        Process.sleep(5)
      end

      {:ok, deltas, _server_hlc, _has_more} =
        Persistence.Sync.get_deltas(@tenant_id, channel, ts_before, 100)

      assert length(deltas) == 3
      assert Enum.all?(deltas, &(&1.type == "MessageAppend"))
    end

    test "incremental sync returns only new messages" do
      channel = :crypto.strong_rand_bytes(16)

      # Write first batch
      for _ <- 1..3 do
        ts = System.system_time(:millisecond)
        bucket = MercuryCore.Native.compute_time_bucket(ts)

        :ok =
          Persistence.Messages.write(@tenant_id, channel, bucket, %{
            message_id: MercuryCore.Native.generate_message_id(),
            sender_id: @sender_id,
            encrypted_content: "batch1",
            content_type: 0,
            reply_to: nil,
            created_at: ts
          })

        Process.sleep(5)
      end

      # Record boundary timestamp AFTER first batch
      Process.sleep(50)
      boundary = System.system_time(:millisecond)
      Process.sleep(50)

      # Write second batch
      for _ <- 1..2 do
        ts = System.system_time(:millisecond)
        bucket = MercuryCore.Native.compute_time_bucket(ts)

        :ok =
          Persistence.Messages.write(@tenant_id, channel, bucket, %{
            message_id: MercuryCore.Native.generate_message_id(),
            sender_id: @sender_id,
            encrypted_content: "batch2",
            content_type: 0,
            reply_to: nil,
            created_at: ts
          })

        Process.sleep(5)
      end

      # Incremental sync from boundary — only new 2
      {:ok, deltas2, _, _} =
        Persistence.Sync.get_deltas(@tenant_id, channel, boundary, 100)

      assert length(deltas2) == 2
    end

    test "apply_deltas rejects batch over 1000" do
      deltas = for _ <- 1..1001, do: %{"type" => "MessageAppend"}
      assert {:error, :too_large} = Persistence.Sync.apply_deltas(@tenant_id, @channel_id, deltas)
    end

    test "apply_deltas persists MessageAppend to ScyllaDB" do
      channel = :crypto.strong_rand_bytes(16)
      msg_id = MercuryCore.Native.generate_message_id()
      ts = System.system_time(:millisecond)

      deltas = [
        %{
          "type" => "MessageAppend",
          "message_id" => Base.encode16(msg_id),
          "sender_id" => Base.encode16(@sender_id),
          "encrypted_content" => Base.encode64("offline msg"),
          "content_type" => 0,
          "hlc_wall" => ts
        }
      ]

      {:ok, 1} = Persistence.Sync.apply_deltas(@tenant_id, channel, deltas)

      bucket = MercuryCore.Native.compute_time_bucket(ts)
      {:ok, msgs} = Persistence.Messages.read(@tenant_id, channel, bucket, 10)
      assert Enum.any?(msgs, &(&1.encrypted_content == "offline msg"))
    end
  end

  describe "Sync cursors" do
    test "update and retrieve cursor" do
      tenant_id = Ecto.UUID.generate()
      user_id = Ecto.UUID.generate()
      device_id = Ecto.UUID.generate()
      channel_id = Ecto.UUID.generate()

      hlc = %{wall: 12_345, counter: 1, node: <<0>>}
      :ok = Persistence.Sync.update_cursor(tenant_id, user_id, device_id, channel_id, hlc)

      cursors = Persistence.Sync.get_cursors(tenant_id, user_id, device_id)
      assert length(cursors) == 1
      cursor = hd(cursors)
      assert cursor.last_hlc_wall == 12_345
      assert cursor.last_hlc_counter == 1

      # Update advances cursor
      hlc2 = %{wall: 99_999, counter: 0, node: <<0>>}
      :ok = Persistence.Sync.update_cursor(tenant_id, user_id, device_id, channel_id, hlc2)

      [updated] = Persistence.Sync.get_cursors(tenant_id, user_id, device_id)
      assert updated.last_hlc_wall == 99_999
    end
  end

  describe "Read positions" do
    test "update and get read position" do
      tid = :crypto.strong_rand_bytes(16)
      uid = :crypto.strong_rand_bytes(16)
      cid = :crypto.strong_rand_bytes(16)

      assert {:error, :not_found} = Persistence.ReadPositions.get(tid, uid, cid)

      mid1 = MercuryCore.Native.generate_message_id()
      :ok = Persistence.ReadPositions.update(tid, uid, cid, mid1)
      assert {:ok, ^mid1} = Persistence.ReadPositions.get(tid, uid, cid)

      # Advance forward
      Process.sleep(2)
      mid2 = MercuryCore.Native.generate_message_id()
      :ok = Persistence.ReadPositions.update(tid, uid, cid, mid2)
      assert {:ok, ^mid2} = Persistence.ReadPositions.get(tid, uid, cid)

      # Never goes backward — older message_id ignored
      :ok = Persistence.ReadPositions.update(tid, uid, cid, mid1)
      assert {:ok, ^mid2} = Persistence.ReadPositions.get(tid, uid, cid)
    end

    test "get_bulk returns positions for multiple channels" do
      tid = :crypto.strong_rand_bytes(16)
      uid = :crypto.strong_rand_bytes(16)
      cid1 = :crypto.strong_rand_bytes(16)
      cid2 = :crypto.strong_rand_bytes(16)
      cid3 = :crypto.strong_rand_bytes(16)

      mid1 = MercuryCore.Native.generate_message_id()
      mid2 = MercuryCore.Native.generate_message_id()
      :ok = Persistence.ReadPositions.update(tid, uid, cid1, mid1)
      :ok = Persistence.ReadPositions.update(tid, uid, cid2, mid2)

      result = Persistence.ReadPositions.get_bulk(tid, uid, [cid1, cid2, cid3])
      assert map_size(result) == 2
      assert result[cid1] == mid1
      assert result[cid2] == mid2
    end
  end
end
