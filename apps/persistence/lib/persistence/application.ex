defmodule Persistence.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    children =
      [
        Persistence.Repo,
        scylla_child(),
        redis_child(),
        nats_child(),
        brod_child(),
        consumer_child()
      ]
      |> List.flatten()

    opts = [strategy: :one_for_one, name: Persistence.Supervisor]
    Supervisor.start_link(children, opts)
  end

  defp scylla_child do
    config = Application.get_env(:persistence, Persistence.Scylla, [])

    if config[:enabled] do
      [
        {Xandra.Cluster,
         Keyword.merge([name: Persistence.Scylla, pool_size: 10], config[:opts] || [])}
      ]
    else
      []
    end
  end

  defp redis_child do
    config = Application.get_env(:persistence, Persistence.Cache, [])

    if config[:enabled] do
      [{Redix, Keyword.merge([name: Persistence.Redis], config[:opts] || [])}]
    else
      []
    end
  end

  defp nats_child do
    config = Application.get_env(:persistence, Persistence.Events, [])

    if config[:enabled] do
      [
        %{
          id: Persistence.Events,
          start: {Gnat, :start_link, [config[:opts] || %{}, [name: Persistence.Nats]]}
        }
      ]
    else
      []
    end
  end

  defp consumer_child do
    config = Application.get_env(:persistence, Persistence.Events, [])
    if config[:enabled], do: [Persistence.Consumer], else: []
  end

  defp brod_child do
    config = Application.get_env(:persistence, Persistence.Audit, [])

    if config[:enabled] do
      endpoints = config[:endpoints] || [{"localhost", 9092}]

      [
        %{
          id: :redpanda_client,
          start:
            {:brod_client, :start_link,
             [
               endpoints,
               :redpanda_client,
               [auto_start_producers: true, allow_topic_auto_creation: true]
             ]}
        }
      ]
    else
      []
    end
  end
end
