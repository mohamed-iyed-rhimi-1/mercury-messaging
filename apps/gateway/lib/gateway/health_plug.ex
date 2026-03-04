defmodule Gateway.HealthPlug do
  @moduledoc "Health check endpoints for Kubernetes probes."
  use Plug.Router

  alias Ecto.Adapters.SQL

  plug(:match)
  plug(:dispatch)

  get "/live" do
    send_resp(conn, 200, Jason.encode!(%{status: "ok"}))
  end

  get "/ready" do
    checks = %{
      scylla: check_scylla(),
      postgres: check_postgres(),
      nats: check_nats(),
      dragonfly: check_dragonfly()
    }

    all_ok = Enum.all?(checks, fn {_, v} -> v == :ok end)
    status = if all_ok, do: 200, else: 503

    body =
      checks
      |> Enum.map(fn {k, v} -> {k, if(v == :ok, do: "ok", else: "down")} end)
      |> Map.new()
      |> Map.put(:status, if(all_ok, do: "ok", else: "degraded"))

    send_resp(conn, status, Jason.encode!(body))
  end

  get "/startup" do
    # Same as ready — startup probe uses longer failure threshold
    call(%{conn | path_info: ["ready"]}, [])
  end

  match _ do
    send_resp(conn, 404, "not found")
  end

  defp check_scylla do
    if Process.whereis(Persistence.Scylla) do
      case Xandra.Cluster.execute(Persistence.Scylla, "SELECT now() FROM system.local") do
        {:ok, _} -> :ok
        _ -> :error
      end
    else
      :error
    end
  rescue
    _ -> :error
  end

  defp check_postgres do
    case SQL.query(Persistence.Repo, "SELECT 1") do
      {:ok, _} -> :ok
      _ -> :error
    end
  rescue
    _ -> :error
  end

  defp check_nats do
    if Process.whereis(Persistence.Nats), do: :ok, else: :error
  end

  defp check_dragonfly do
    if Process.whereis(Persistence.Redis) do
      case Redix.command(Persistence.Redis, ["PING"]) do
        {:ok, "PONG"} -> :ok
        _ -> :error
      end
    else
      :error
    end
  rescue
    _ -> :error
  end
end
