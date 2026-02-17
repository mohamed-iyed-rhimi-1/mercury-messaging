defmodule Gateway.AuthTest do
  use ExUnit.Case, async: true

  @tenant_id :crypto.strong_rand_bytes(16)
  @user_id :crypto.strong_rand_bytes(16)
  @device_id :crypto.strong_rand_bytes(16)

  test "generate and verify token roundtrip" do
    token = Gateway.Auth.generate_token(@tenant_id, @user_id, @device_id)
    assert {:ok, claims} = Gateway.Auth.verify_token(token)
    assert claims.tenant_id == @tenant_id
    assert claims.user_id == @user_id
    assert claims.device_id == @device_id
  end

  test "rejects invalid token" do
    assert {:error, _} = Gateway.Auth.verify_token("garbage.token.here")
  end

  test "rejects tampered token" do
    token = Gateway.Auth.generate_token(@tenant_id, @user_id, @device_id)
    tampered = token <> "x"
    assert {:error, _} = Gateway.Auth.verify_token(tampered)
  end
end
