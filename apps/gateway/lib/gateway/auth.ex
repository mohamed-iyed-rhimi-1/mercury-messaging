defmodule Gateway.Auth do
  @moduledoc "JWT authentication. Extracts tenant_id, user_id, device_id from token."

  @spec verify_token(binary()) ::
          {:ok, %{tenant_id: binary(), user_id: binary(), device_id: binary()}}
          | {:error,
             :invalid_token | :invalid_claim | :missing_claim | :missing_expiry | :token_expired}
  def verify_token(token) do
    secret = Application.get_env(:gateway, __MODULE__)[:jwt_secret] || "dev_secret"
    signer = Joken.Signer.create("HS256", secret)

    case Joken.verify(token, signer) do
      {:ok, claims} ->
        with {:ok, tenant_id} <- fetch_binary_claim(claims, "tid"),
             {:ok, user_id} <- fetch_binary_claim(claims, "uid"),
             {:ok, device_id} <- fetch_binary_claim(claims, "did"),
             :ok <- check_expiry(claims) do
          {:ok, %{tenant_id: tenant_id, user_id: user_id, device_id: device_id}}
        end

      {:error, _reason} ->
        {:error, :invalid_token}
    end
  end

  @spec generate_token(binary(), binary(), binary()) :: binary()
  def generate_token(tenant_id, user_id, device_id) do
    secret = Application.get_env(:gateway, __MODULE__)[:jwt_secret] || "dev_secret"
    signer = Joken.Signer.create("HS256", secret)

    claims = %{
      "tid" => Base.encode16(tenant_id),
      "uid" => Base.encode16(user_id),
      "did" => Base.encode16(device_id),
      "exp" => System.system_time(:second) + 86_400
    }

    {:ok, token, _claims} = Joken.encode_and_sign(claims, signer)
    token
  end

  defp fetch_binary_claim(claims, key) do
    case Map.fetch(claims, key) do
      {:ok, hex} when is_binary(hex) ->
        case Base.decode16(hex) do
          {:ok, bin} -> {:ok, bin}
          :error -> {:error, :invalid_claim}
        end

      _ ->
        {:error, :missing_claim}
    end
  end

  defp check_expiry(claims) do
    case Map.fetch(claims, "exp") do
      {:ok, exp} when is_number(exp) ->
        if System.system_time(:second) < exp, do: :ok, else: {:error, :token_expired}

      _ ->
        {:error, :missing_expiry}
    end
  end
end
