defmodule Gateway.NativeTest do
  use ExUnit.Case, async: true

  @tenant_id :crypto.strong_rand_bytes(16)
  @channel_id :crypto.strong_rand_bytes(16)
  @user_id :crypto.strong_rand_bytes(16)
  @node_id :crypto.strong_rand_bytes(16)

  describe "generate_message_id/0" do
    test "returns 16 bytes" do
      id = Gateway.Native.generate_message_id()
      assert byte_size(id) == 16
    end

    test "ids are unique" do
      a = Gateway.Native.generate_message_id()
      b = Gateway.Native.generate_message_id()
      assert a != b
    end

    test "ids are sortable (later > earlier)" do
      a = Gateway.Native.generate_message_id()
      Process.sleep(2)
      b = Gateway.Native.generate_message_id()
      assert b > a
    end
  end

  describe "generate_channel_id/0" do
    test "returns 16 bytes" do
      id = Gateway.Native.generate_channel_id()
      assert byte_size(id) == 16
    end
  end

  describe "compute_time_bucket/1" do
    test "known timestamp" do
      ts = 1_704_067_200_000
      bucket = Gateway.Native.compute_time_bucket(ts)
      assert bucket == 1972
    end

    test "same bucket within 10 days" do
      bucket_start = 1972 * 10 * 86_400_000
      day9 = bucket_start + 9 * 86_400_000

      assert Gateway.Native.compute_time_bucket(bucket_start) ==
               Gateway.Native.compute_time_bucket(day9)
    end
  end

  describe "validate_message/5" do
    test "valid text message" do
      assert {:ok, :ok} =
               Gateway.Native.validate_message(@tenant_id, @channel_id, @user_id, "hello", 0)
    end

    test "rejects empty content for text" do
      assert {:error, :invalid_message} =
               Gateway.Native.validate_message(@tenant_id, @channel_id, @user_id, "", 0)
    end

    test "rejects oversized content" do
      big = :binary.copy(<<0>>, 256 * 1024 + 1)

      assert {:error, :invalid_message} =
               Gateway.Native.validate_message(@tenant_id, @channel_id, @user_id, big, 0)
    end

    test "rejects invalid content type" do
      assert {:error, :invalid_content_type} =
               Gateway.Native.validate_message(@tenant_id, @channel_id, @user_id, "hello", 99)
    end
  end

  describe "validate_channel/3" do
    test "valid DM (no name)" do
      assert {:ok, :ok} = Gateway.Native.validate_channel(@tenant_id, 0, nil)
    end

    test "valid group with name" do
      assert {:ok, :ok} = Gateway.Native.validate_channel(@tenant_id, 1, "general")
    end

    test "rejects DM with name" do
      assert {:error, :invalid_channel} = Gateway.Native.validate_channel(@tenant_id, 0, "oops")
    end

    test "rejects group without name" do
      assert {:error, :invalid_channel} = Gateway.Native.validate_channel(@tenant_id, 1, nil)
    end
  end

  describe "hlc_tick/3" do
    test "advances clock" do
      {wall, counter} = Gateway.Native.hlc_tick(1000, 0, @node_id)
      assert wall >= 1000
      assert is_integer(counter)
    end
  end

  describe "hlc_merge/6" do
    test "picks max wall clock" do
      {wall, _counter} = Gateway.Native.hlc_merge(100, 0, @node_id, 200, 5, @node_id)
      assert wall >= 200
    end
  end
end
