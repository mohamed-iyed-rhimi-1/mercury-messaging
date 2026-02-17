defmodule Gateway.BinaryUpgrade do
  @moduledoc "Plug that authenticates via JWT and upgrades to BinarySocket."
  @behaviour Plug

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, _opts) do
    token = conn.params["token"] || ""

    case Gateway.Auth.verify_token(token) do
      {:ok, claims} ->
        WebSockAdapter.upgrade(conn, Gateway.BinarySocket, claims,
          timeout: 60_000,
          compress: true,
          max_frame_size: 262_144
        )

      {:error, _reason} ->
        conn
        |> Plug.Conn.send_resp(401, "unauthorized")
        |> Plug.Conn.halt()
    end
  end
end
