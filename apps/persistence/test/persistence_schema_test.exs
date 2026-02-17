defmodule Persistence.SchemaTest do
  use ExUnit.Case, async: true

  alias Persistence.Schema.{Channel, ChannelMember, Device, Tenant, User}

  describe "Tenant" do
    test "valid changeset" do
      cs = Tenant.changeset(%Tenant{}, %{name: "Acme Corp"})
      assert cs.valid?
    end

    test "rejects empty name" do
      cs = Tenant.changeset(%Tenant{}, %{name: ""})
      refute cs.valid?
    end

    test "rejects invalid plan" do
      cs = Tenant.changeset(%Tenant{}, %{name: "Acme", plan: "invalid"})
      refute cs.valid?
    end

    test "accepts valid plans" do
      for plan <- ["free", "pro", "enterprise"] do
        cs = Tenant.changeset(%Tenant{}, %{name: "Acme", plan: plan})
        assert cs.valid?, "Expected plan #{plan} to be valid"
      end
    end
  end

  describe "User" do
    test "valid changeset" do
      cs = User.changeset(%User{}, %{tenant_id: Ecto.UUID.generate(), display_name: "Alice"})
      assert cs.valid?
    end

    test "rejects name over 64 chars" do
      cs =
        User.changeset(%User{}, %{
          tenant_id: Ecto.UUID.generate(),
          display_name: String.duplicate("a", 65)
        })

      refute cs.valid?
    end
  end

  describe "Channel" do
    test "valid group channel" do
      cs =
        Channel.changeset(%Channel{}, %{
          tenant_id: Ecto.UUID.generate(),
          channel_type: 1,
          name: "general",
          created_by: Ecto.UUID.generate()
        })

      assert cs.valid?
    end

    test "rejects invalid channel_type" do
      cs =
        Channel.changeset(%Channel{}, %{
          tenant_id: Ecto.UUID.generate(),
          channel_type: 5,
          created_by: Ecto.UUID.generate()
        })

      refute cs.valid?
    end
  end

  describe "ChannelMember" do
    test "valid membership" do
      cs =
        ChannelMember.changeset(%ChannelMember{}, %{
          tenant_id: Ecto.UUID.generate(),
          channel_id: Ecto.UUID.generate(),
          user_id: Ecto.UUID.generate(),
          role: 0
        })

      assert cs.valid?
    end

    test "rejects invalid role" do
      cs =
        ChannelMember.changeset(%ChannelMember{}, %{
          tenant_id: Ecto.UUID.generate(),
          channel_id: Ecto.UUID.generate(),
          user_id: Ecto.UUID.generate(),
          role: 5
        })

      refute cs.valid?
    end
  end

  describe "Device" do
    test "valid changeset" do
      cs =
        Device.changeset(%Device{}, %{
          tenant_id: Ecto.UUID.generate(),
          user_id: Ecto.UUID.generate(),
          device_name: "iPhone 15",
          platform: "ios"
        })

      assert cs.valid?
    end

    test "rejects invalid platform" do
      cs =
        Device.changeset(%Device{}, %{
          tenant_id: Ecto.UUID.generate(),
          user_id: Ecto.UUID.generate(),
          device_name: "Test",
          platform: "blackberry"
        })

      refute cs.valid?
    end

    test "requires device_name" do
      cs =
        Device.changeset(%Device{}, %{
          tenant_id: Ecto.UUID.generate(),
          user_id: Ecto.UUID.generate(),
          platform: "web"
        })

      refute cs.valid?
    end
  end
end
