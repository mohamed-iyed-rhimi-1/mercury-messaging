defmodule LoadTest.WsClient do
  @moduledoc false
  import Bitwise

  def connect(host, port, path, owner \\ nil) do
    key = Base.encode64(:crypto.strong_rand_bytes(16))

    with {:ok, sock} <- :gen_tcp.connect(String.to_charlist(host), port, [:binary, active: false]),
         :ok <-
           :gen_tcp.send(sock, [
             "GET #{path} HTTP/1.1\r\n",
             "Host: #{host}:#{port}\r\n",
             "Upgrade: websocket\r\nConnection: Upgrade\r\n",
             "Sec-WebSocket-Key: #{key}\r\nSec-WebSocket-Version: 13\r\n\r\n"
           ]),
         {:ok, resp} <- :gen_tcp.recv(sock, 0, 5_000) do
      if String.contains?(resp, "101") do
        if owner, do: :gen_tcp.controlling_process(sock, owner)
        {:ok, sock}
      else
        {:error, resp}
      end
    end
  end

  def send_text(sock, payload) do
    mask = :crypto.strong_rand_bytes(4)
    len = byte_size(payload)
    masked = mask_payload(payload, mask)

    header =
      if len < 126,
        do: <<0x81, 0x80 ||| len, mask::binary-4>>,
        else: <<0x81, 0x80 ||| 126, len::16, mask::binary-4>>

    :gen_tcp.send(sock, [header, masked])
  end

  def recv(sock, timeout \\ 2_000), do: :gen_tcp.recv(sock, 0, timeout)

  defp mask_payload(payload, <<m0, m1, m2, m3>>) do
    mask = [m0, m1, m2, m3]

    for {byte, i} <- Enum.with_index(:binary.bin_to_list(payload)),
        into: <<>>,
        do: <<Bitwise.bxor(byte, Enum.at(mask, rem(i, 4)))>>
  end

  def close(sock), do: :gen_tcp.close(sock)
end

defmodule LoadTest.Gateway do
  @moduledoc false

  @host "127.0.0.1"

  def run(opts \\ []) do
    num = Keyword.get(opts, :connections, 1_000)
    msgs_per_conn = Keyword.get(opts, :msgs_per_conn, 10)
    port = Keyword.get(opts, :port, 4000)
    total = num * msgs_per_conn
    caller = self()

    IO.puts("\n=== Mercury Gateway Load Test ===")
    IO.puts("Connections: #{num} | Msgs/conn: #{msgs_per_conn} | Total: #{total}\n")

    tenant_id = :crypto.strong_rand_bytes(16)

    # Phase 1: Connect — transfer socket ownership to caller
    IO.puts("--- Phase 1: Connect ---")

    {conn_us, sockets} =
      :timer.tc(fn ->
        1..num
        |> Task.async_stream(
          fn i ->
            token = Gateway.Auth.generate_token(tenant_id, <<i::128>>, <<i::128>>)
            path = "/ws?token=#{URI.encode_www_form(token)}&vsn=2.0.0"
            LoadTest.WsClient.connect(@host, port, path, caller)
          end,
          max_concurrency: 100,
          timeout: 30_000,
          ordered: false
        )
        |> Enum.flat_map(fn {:ok, {:ok, s}} -> [s]; _ -> [] end)
      end)

    connected = length(sockets)
    IO.puts("#{connected}/#{num} in #{div(conn_us, 1_000)}ms\n")

    if connected == 0 do
      IO.puts("ERROR: No connections.")
      :error
    else
      # Phase 2+3: Join + Send — transfer ownership to each task
      IO.puts("--- Phase 2: Join + Send ---")

      {total_us, {ok_count, err_count, latencies}} =
        :timer.tc(fn ->
          sockets
          |> Enum.with_index()
          |> Task.async_stream(
            fn {sock, i} ->
              # Take ownership of this socket in this task
              :gen_tcp.controlling_process(sock, self())
              topic = "channel:load#{i}"

              join = Jason.encode!(["1", "1", topic, "phx_join", %{}])

              with :ok <- LoadTest.WsClient.send_text(sock, join),
                   {:ok, _} <- LoadTest.WsClient.recv(sock, 5_000) do
                Enum.map(1..msgs_per_conn, fn j ->
                  msg =
                    Jason.encode!([
                      "1",
                      "#{i}-#{j}",
                      topic,
                      "msg:send",
                      %{"content" => "m", "content_type" => 0}
                    ])

                  t0 = System.monotonic_time(:microsecond)

                  case LoadTest.WsClient.send_text(sock, msg) do
                    :ok -> {:ok, System.monotonic_time(:microsecond) - t0}
                    err -> {:error, err}
                  end
                end)
              else
                err -> [{:error, {:join_failed, err}}]
              end
            end,
            max_concurrency: 100,
            timeout: 60_000,
            ordered: false
          )
          |> Enum.reduce({0, 0, []}, fn {:ok, results}, {ok, err, lats} ->
            Enum.reduce(results, {ok, err, lats}, fn
              {:ok, lat}, {o, e, l} -> {o + 1, e, [lat | l]}
              {:error, _}, {o, e, l} -> {o, e + 1, l}
            end)
          end)
        end)

      sorted = Enum.sort(latencies)
      n = ok_count
      total_sec = max(total_us / 1_000_000, 0.001)
      throughput = round(n / total_sec)

      IO.puts("\n--- Results ---")
      IO.puts("Connections: #{connected}")
      IO.puts("Messages sent: #{n} | Errors: #{err_count}")
      IO.puts("Wall time: #{round(total_us / 1_000)}ms")
      IO.puts("Throughput: #{throughput} msg/sec")

      if n > 0 do
        IO.puts("\nSend latency (µs):")
        IO.puts("  P50:  #{pct(sorted, 0.50)}")
        IO.puts("  P95:  #{pct(sorted, 0.95)}")
        IO.puts("  P99:  #{pct(sorted, 0.99)}")
        IO.puts("  Max:  #{List.last(sorted)}")
      end

      IO.puts("\n--- Acceptance Criteria ---")
      check("Connections >= 1000", connected >= 1000)
      check("Throughput >= 1000 msg/sec", throughput >= 1000)
      if n > 0, do: check("P99 send < 5000µs (5ms)", pct(sorted, 0.99) < 5000)
      IO.puts("")

      Enum.each(sockets, &LoadTest.WsClient.close/1)
      :ok
    end
  end

  defp pct(sorted, p), do: Enum.at(sorted, max(round(p * length(sorted)) - 1, 0))
  defp check(label, true), do: IO.puts("  ✅ #{label}")
  defp check(label, false), do: IO.puts("  ❌ #{label}")
end
