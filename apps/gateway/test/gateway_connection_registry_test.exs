defmodule Gateway.ConnectionRegistryTest do
  use ExUnit.Case, async: false

  setup do
    # Registry is started by the application supervisor
    :ok
  end

  @tid <<1::128>>
  @uid <<2::128>>
  @did <<3::128>>

  test "register and lookup" do
    Gateway.ConnectionRegistry.register(@tid, @uid, @did, self())
    assert {:ok, pid} = Gateway.ConnectionRegistry.lookup(@tid, @uid, @did)
    assert pid == self()
  end

  test "lookup returns :not_found for unknown" do
    assert :not_found = Gateway.ConnectionRegistry.lookup(<<99::128>>, <<99::128>>, <<99::128>>)
  end

  test "unregister removes entry" do
    Gateway.ConnectionRegistry.register(@tid, @uid, <<4::128>>, self())
    Gateway.ConnectionRegistry.unregister(@tid, @uid, <<4::128>>)
    assert :not_found = Gateway.ConnectionRegistry.lookup(@tid, @uid, <<4::128>>)
  end

  test "user_devices returns all device pids" do
    pid1 = self()
    Gateway.ConnectionRegistry.register(@tid, @uid, <<10::128>>, pid1)
    Gateway.ConnectionRegistry.register(@tid, @uid, <<11::128>>, pid1)
    devices = Gateway.ConnectionRegistry.user_devices(@tid, @uid)
    assert length(devices) >= 2
  end
end
