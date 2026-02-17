# Phase 2: Real-time Gateway in Elixir — Implementation Plan

**Timeline:** Weeks 6–12 (30 working days)
**Goal:** Phoenix-based WebSocket gateway that authenticates connections, routes messages between clients via PubSub, tracks presence, and delegates validation/crypto to Rust NIFs. No database persistence yet — messages are routed in-memory only.

**Prerequisites:** Phase 1 complete (mercury-core, mercury-crdt, mercury-crypto all green). Elixir umbrella scaffolded (Phase 0). Docker Compose services running.

---

## Day-by-Day Breakdown

### Days 1–5: Rust NIF Bridge (`mercury-nif`) (Step 2.2)

Build the Rust→Elixir bridge first so all subsequent Elixir code can call into Rust for validation and crypto.

**Day 1 — Rustler Setup + First NIF**

Add Rustler to mercury-nif:

```toml
# crates/mercury-nif/Cargo.toml — add to [dependencies]
rustler = { version = "0.36", features = ["nif_version_2_17"] }
mercury-core = { path = "../mercury-core" }
mercury-crdt = { path = "../mercury-crdt" }
mercury-crypto = { path = "../mercury-crypto" }
```

Add the Elixir-side NIF wrapper to the gateway app:

```elixir
# apps/gateway/mix.exs — add to deps
{:rustler, "~> 0.36"},
{:jason, "~> 1.4"}
```

Implement the first NIF — `compute_time_bucket`:

```rust
// crates/mercury-nif/src/lib.rs
use mercury_core::TimeBucket;
use rustler::{Env, Term, NifResult};

#[rustler::nif]
fn compute_time_bucket(timestamp_ms: u64) -> u32 {
    TimeBucket::from_timestamp_ms(timestamp_ms).as_u32()
}

rustler::init!("Elixir.Gateway.Native");
```

```elixir
# apps/gateway/lib/gateway/native.ex
defmodule Gateway.Native do
  use Rustler, otp_app: :gateway, crate: "mercury_nif"

  @spec compute_time_bucket(non_neg_integer()) :: non_neg_integer()
  def compute_time_bucket(_timestamp_ms), do: :erlang.nif_error(:nif_not_loaded)
end
```

Test the NIF loads and returns correct values.

**Day 2 — Validation NIFs**

Add message and channel validation NIFs. These accept raw binary (Cap'n Proto or JSON for now) and return `{:ok, map}` or `{:error, reason}`:

```rust
#[rustler::nif]
fn validate_message(
    tenant_id: Binary,
    channel_id: Binary,
    sender_id: Binary,
    content: Binary,
    content_type: u8,
) -> NifResult<Atom> {
    // Construct Message from args, call validate(), return :ok or {:error, reason}
}
```

NIFs to implement on Day 2:
- `validate_message/5` — Constructs `Message`, calls `validate()`, returns `:ok` or `{:error, binary}`
- `validate_channel/3` — Constructs `Channel`, calls `validate()`, returns `:ok` or `{:error, binary}`
- `generate_message_id/0` — Returns 16-byte ULID binary
- `generate_channel_id/0` — Returns 16-byte UUIDv4 binary

**Day 3 — HLC + Crypto NIFs**

```rust
#[rustler::nif(schedule = "DirtyCpu")]
fn hlc_tick(wall_clock_ms: u64, counter: u64, node_id: Binary) -> (u64, u64) {
    // Construct Hlc, tick(), return (new_wall_clock, new_counter)
}

#[rustler::nif(schedule = "DirtyCpu")]
fn hlc_merge(
    local_wall: u64, local_counter: u64, local_node: Binary,
    remote_wall: u64, remote_counter: u64, remote_node: Binary,
) -> (u64, u64) {
    // Merge two HLCs, return merged (wall_clock, counter)
}

#[rustler::nif(schedule = "DirtyCpu")]
fn encrypt_message(plaintext: Binary) -> NifResult<Binary> {
    // NoopEncryptor for now — passthrough
}

#[rustler::nif(schedule = "DirtyCpu")]
fn decrypt_message(ciphertext: Binary) -> NifResult<Binary> {
    // NoopEncryptor for now — passthrough
}
```

Key: crypto and HLC NIFs use `schedule = "DirtyCpu"` to avoid blocking the BEAM scheduler.

**Day 4 — Elixir-side NIF Wrapper Module + Tests**

Create `Gateway.Native` with typed wrappers and fallback error handling:

```elixir
defmodule Gateway.Native do
  use Rustler, otp_app: :gateway, crate: "mercury_nif"

  # Each function has a fallback that raises if NIF isn't loaded
  def compute_time_bucket(_ts), do: :erlang.nif_error(:nif_not_loaded)
  def validate_message(_t, _ch, _s, _c, _ct), do: :erlang.nif_error(:nif_not_loaded)
  def validate_channel(_t, _type, _name), do: :erlang.nif_error(:nif_not_loaded)
  def generate_message_id(), do: :erlang.nif_error(:nif_not_loaded)
  def generate_channel_id(), do: :erlang.nif_error(:nif_not_loaded)
  def hlc_tick(_w, _c, _n), do: :erlang.nif_error(:nif_not_loaded)
  def hlc_merge(_lw, _lc, _ln, _rw, _rc, _rn), do: :erlang.nif_error(:nif_not_loaded)
  def encrypt_message(_plaintext), do: :erlang.nif_error(:nif_not_loaded)
  def decrypt_message(_ciphertext), do: :erlang.nif_error(:nif_not_loaded)
end
```

Write ExUnit tests for every NIF function. Verify:
- `compute_time_bucket` matches Rust unit test values
- `validate_message` rejects empty content, oversized content (>256KB), self-reply
- `generate_message_id` returns 16 bytes, is sortable
- HLC tick advances, merge picks max
- Encrypt/decrypt roundtrips (noop for now)

**Day 5 — NIF Safety + Benchmark**

- Verify NIFs don't block the BEAM: run `:observer.start()`, send 10K NIF calls, confirm scheduler utilization stays balanced.
- Add `@spec` typespecs to all NIF functions.
- Run `mix dialyzer` — zero warnings.
- Benchmark NIF call overhead: measure round-trip time for `compute_time_bucket` (should be <1µs including NIF crossing overhead).

**Day 5 Deliverables Checkpoint:**
- [ ] 9 NIF functions callable from Elixir
- [ ] All NIFs tested in ExUnit
- [ ] Dirty scheduler verified for crypto/HLC NIFs
- [ ] Dialyzer clean

---

### Days 6–10: Phoenix WebSocket Gateway (Step 2.1 + 2.3)

**Day 6 — Phoenix Dependencies + Endpoint**

Add Phoenix to the gateway app:

```elixir
# apps/gateway/mix.exs — deps
{:phoenix, "~> 1.7"},
{:phoenix_pubsub, "~> 2.1"},
{:jason, "~> 1.4"},
{:bandit, "~> 1.6"},
{:telemetry, "~> 1.3"},
{:telemetry_metrics, "~> 1.0"},
{:telemetry_poller, "~> 1.1"}
```

Create the Phoenix endpoint with WebSocket transport:

```elixir
# apps/gateway/lib/gateway/endpoint.ex
defmodule Gateway.Endpoint do
  use Phoenix.Endpoint, otp_app: :gateway

  socket "/ws", Gateway.MercurySocket,
    websocket: [
      timeout: 60_000,
      compress: true,
      max_frame_size: 262_144  # 256KB — matches Rust MAX_CONTENT_SIZE
    ]
end
```

```elixir
# apps/gateway/lib/gateway/mercury_socket.ex
defmodule Gateway.MercurySocket do
  use Phoenix.Socket

  channel "channel:*", Gateway.MessageChannel
  channel "presence:*", Gateway.PresenceChannel

  @impl true
  def connect(params, socket, _connect_info) do
    # Extract tenant_id + user_id from auth token
    # Assign to socket for all subsequent channel joins
  end

  @impl true
  def id(socket), do: "user:#{socket.assigns.tenant_id}:#{socket.assigns.user_id}"
end
```

Wire into the supervision tree in `Gateway.Application`.

**Day 7 — Authentication (JWT)**

Implement JWT validation in the socket connect:

```elixir
defmodule Gateway.Auth do
  @max_token_age 86_400  # 24h — NASA Rule #2: bounded

  @spec verify_token(binary()) :: {:ok, map()} | {:error, atom()}
  def verify_token(token) do
    # Decode JWT, verify signature, check expiry
    # Extract: tenant_id, user_id, device_id
    # Return {:ok, %{tenant_id: _, user_id: _, device_id: _}}
  end
end
```

For Phase 2, use a simple HMAC-SHA256 JWT with a shared secret (config). Full WebAuthn/passkey auth comes in Phase 3. The JWT must contain `tenant_id` — this is the multi-tenancy enforcement point.

Wire `Gateway.Auth.verify_token/1` into `MercurySocket.connect/3`. Reject connections with invalid/expired tokens.

**Day 8 — Connection Registry (ETS)**

```elixir
defmodule Gateway.ConnectionRegistry do
  @moduledoc "ETS-based registry: {tenant_id, user_id, device_id} → pid. O(1) lookup."
  use GenServer

  @table __MODULE__

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  def init([]) do
    :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    {:ok, %{}}
  end

  @spec register(binary(), binary(), binary(), pid()) :: :ok
  def register(tenant_id, user_id, device_id, pid) do
    :ets.insert(@table, {{tenant_id, user_id, device_id}, pid})
    :ok
  end

  @spec unregister(binary(), binary(), binary()) :: :ok
  def unregister(tenant_id, user_id, device_id) do
    :ets.delete(@table, {tenant_id, user_id, device_id})
    :ok
  end

  @spec lookup(binary(), binary(), binary()) :: {:ok, pid()} | :not_found
  def lookup(tenant_id, user_id, device_id) do
    case :ets.lookup(@table, {tenant_id, user_id, device_id}) do
      [{_key, pid}] -> {:ok, pid}
      [] -> :not_found
    end
  end

  @spec user_devices(binary(), binary()) :: [pid()]
  def user_devices(tenant_id, user_id) do
    # Match on {tenant_id, user_id, _} — returns all device pids
    :ets.match_object(@table, {{tenant_id, user_id, :_}, :_})
    |> Enum.map(fn {_key, pid} -> pid end)
  end
end
```

Add to supervision tree. Register connections on socket connect, unregister on disconnect.

**Day 9 — Rate Limiter (Token Bucket)**

```elixir
defmodule Gateway.RateLimiter do
  @moduledoc "Per-user token bucket rate limiter backed by ETS."
  use GenServer

  @table __MODULE__
  @default_rate 100        # messages per second
  @default_burst 150       # burst allowance
  @refill_interval 1_000   # ms — refill every second

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  def init([]) do
    :ets.new(@table, [:named_table, :public, :set, write_concurrency: true])
    schedule_refill()
    {:ok, %{}}
  end

  @spec allow?(binary(), binary()) :: boolean()
  def allow?(tenant_id, user_id) do
    key = {tenant_id, user_id}
    case :ets.lookup(@table, key) do
      [{^key, tokens}] when tokens > 0 ->
        :ets.update_counter(@table, key, {2, -1})
        true
      [{^key, _}] ->
        false
      [] ->
        :ets.insert(@table, {key, @default_burst - 1})
        true
    end
  end

  def handle_info(:refill, state) do
    # Refill all buckets up to burst limit
    :ets.foldl(fn {key, tokens}, _acc ->
      new = min(tokens + @default_rate, @default_burst)
      :ets.insert(@table, {key, new})
      nil
    end, nil, @table)
    schedule_refill()
    {:noreply, state}
  end

  defp schedule_refill, do: Process.send_after(self(), :refill, @refill_interval)
end
```

**Day 10 — Heartbeat + Backpressure**

Add heartbeat tracking to the socket:
- Server sends ping every 30s. Client must respond within 30s.
- 3 missed heartbeats → disconnect.
- Phoenix WebSocket transport handles this natively via `timeout: 60_000` — but we add explicit tracking for telemetry.

Backpressure:
- Track outbound queue size per connection in socket assigns.
- If queue exceeds 1000 messages, drop oldest and send a `{:system, :backpressure}` frame to client.
- Bounded constant: `@max_send_buffer 1_000`.

**Day 10 Deliverables Checkpoint:**
- [ ] Phoenix endpoint accepting WebSocket connections
- [ ] JWT auth on connect (tenant_id extracted)
- [ ] ETS connection registry with register/unregister/lookup
- [ ] Token bucket rate limiter
- [ ] Heartbeat + backpressure handling
- [ ] All wired into supervision tree

---

### Days 11–17: Message Routing + Channels (Step 2.4)

**Day 11 — PubSub Configuration**

Configure Phoenix.PubSub in the gateway application supervisor:

```elixir
# In Gateway.Application.start/2 children:
{Phoenix.PubSub, name: Gateway.PubSub}
```

Topic naming convention (tenant-scoped):
- `"#{tenant_id}:channel:#{channel_id}"` — channel messages
- `"#{tenant_id}:user:#{user_id}"` — cross-device sync
- `"#{tenant_id}:presence:#{channel_id}"` — presence updates

**Day 12 — MessageChannel (Phoenix Channel)**

```elixir
defmodule Gateway.MessageChannel do
  use Phoenix.Channel

  @max_history 50  # NASA Rule #2: bounded

  @impl true
  def join("channel:" <> channel_id, _params, socket) do
    tenant_id = socket.assigns.tenant_id
    user_id = socket.assigns.user_id

    # TODO (Phase 3): verify membership from DB
    # For now, allow all joins within same tenant

    send(self(), :after_join)
    {:ok, assign(socket, :channel_id, channel_id)}
  end

  @impl true
  def handle_in("msg:send", payload, socket) do
    tenant_id = socket.assigns.tenant_id
    user_id = socket.assigns.user_id
    channel_id = socket.assigns.channel_id

    # 1. Rate limit check
    # 2. Validate via Rust NIF
    # 3. Generate message_id via NIF
    # 4. Broadcast to channel topic
    # 5. Emit telemetry event
  end

  @impl true
  def handle_in("msg:typing", _payload, socket) do
    # Broadcast typing indicator (ephemeral, no persistence)
    broadcast_from(socket, "msg:typing", %{
      user_id: socket.assigns.user_id
    })
    {:noreply, socket}
  end
end
```

**Day 13 — Message Flow Implementation**

Implement the full `handle_in("msg:send", ...)` flow:

1. `Gateway.RateLimiter.allow?(tenant_id, user_id)` — reject if rate limited
2. `Gateway.Native.validate_message(tenant_id, channel_id, sender_id, content, content_type)` — reject if invalid
3. `Gateway.Native.generate_message_id()` — get ULID
4. `Gateway.Native.encrypt_message(content)` — encrypt (noop for now)
5. Build message envelope: `%{id: msg_id, sender: user_id, content: encrypted, ts: System.system_time(:millisecond)}`
6. `broadcast!(socket, "msg:new", envelope)` — push to all channel subscribers
7. Emit `:telemetry.execute([:gateway, :message, :sent], %{count: 1}, metadata)`

Return `{:reply, {:ok, %{id: msg_id}}, socket}` on success, `{:reply, {:error, reason}, socket}` on failure.

**Day 14 — Fanout App Integration**

Wire the `fanout` app to consume PubSub messages and handle cross-channel concerns:

```elixir
defmodule Fanout.Worker do
  @moduledoc "Subscribes to channel topics, handles fan-out to offline queues and cross-device sync."
  use GenServer

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  def init(opts) do
    topic = Keyword.fetch!(opts, :topic)
    Phoenix.PubSub.subscribe(Gateway.PubSub, topic)
    {:ok, %{topic: topic}}
  end

  def handle_info(%{event: "msg:new"} = msg, state) do
    # Phase 2: just log. Phase 3: persist to ScyllaDB.
    # Phase 5: queue for offline users.
    {:noreply, state}
  end
end
```

For Phase 2, the fanout worker is a stub — it subscribes and logs. Persistence comes in Phase 3.

**Day 15 — Cross-Device Routing**

When a message is sent, also publish to the sender's user topic so their other devices receive it:

```elixir
# After broadcasting to channel, also notify sender's other devices:
Phoenix.PubSub.broadcast(
  Gateway.PubSub,
  "#{tenant_id}:user:#{user_id}",
  {:sync, :new_message, envelope}
)
```

**Day 16 — Telemetry Events**

Define and emit telemetry events at every key point:

```elixir
defmodule Gateway.Telemetry do
  @events [
    [:gateway, :connection, :opened],
    [:gateway, :connection, :closed],
    [:gateway, :connection, :auth_failed],
    [:gateway, :message, :received],
    [:gateway, :message, :sent],
    [:gateway, :message, :validation_failed],
    [:gateway, :message, :rate_limited],
    [:gateway, :presence, :join],
    [:gateway, :presence, :leave],
    [:gateway, :nif, :call]
  ]

  def events, do: @events
end
```

Attach a console reporter for dev (log telemetry events). In Phase 7, these feed into OpenTelemetry → Grafana.

**Day 17 — Message Routing Integration Tests**

Write integration tests that:
1. Connect two WebSocket clients to the same channel
2. Client A sends a message
3. Client B receives it
4. Verify message envelope structure (id, sender, content, timestamp)
5. Verify rate limiting: send 200 messages in 1 second, confirm throttling kicks in
6. Verify invalid messages are rejected (empty content, oversized)
7. Verify tenant isolation: client from tenant A cannot join tenant B's channel

Use `Phoenix.ChannelTest` for unit tests and raw WebSocket client for integration tests.

**Day 17 Deliverables Checkpoint:**
- [ ] MessageChannel handles join, msg:send, msg:typing
- [ ] Full message flow: validate → encrypt → broadcast → reply
- [ ] PubSub topics are tenant-scoped
- [ ] Cross-device routing via user topic
- [ ] Telemetry events emitted at all key points
- [ ] Integration tests for send/receive/rate-limit/validation/tenant-isolation

---

### Days 18–23: Presence Tracking (Step 2.5)

**Day 18 — Phoenix.Presence Setup**

Add Phoenix.Presence to the `presence` app:

```elixir
# apps/presence/mix.exs — add dep
{:phoenix_pubsub, "~> 2.1"}
```

```elixir
defmodule Presence.Tracker do
  use Phoenix.Presence,
    otp_app: :presence,
    pubsub_server: Gateway.PubSub

  @type presence_meta :: %{
    status: :online | :away,
    device_id: binary(),
    last_seen: integer()
  }
end
```

**Day 19 — Presence Channel**

```elixir
defmodule Gateway.PresenceChannel do
  use Phoenix.Channel

  @impl true
  def join("presence:" <> channel_id, _params, socket) do
    send(self(), :after_join)
    {:ok, assign(socket, :channel_id, channel_id)}
  end

  @impl true
  def handle_info(:after_join, socket) do
    tenant_id = socket.assigns.tenant_id
    user_id = socket.assigns.user_id
    device_id = socket.assigns.device_id

    Presence.Tracker.track(socket, user_id, %{
      status: :online,
      device_id: device_id,
      last_seen: System.system_time(:millisecond)
    })

    push(socket, "presence_state", Presence.Tracker.list(socket))
    {:noreply, socket}
  end
end
```

**Day 20 — Presence Compaction**

Aggregate multi-device presence into a single user status:

```elixir
defmodule Presence.Compactor do
  @moduledoc "Compacts per-device presence into per-user status."

  @spec compact(map()) :: map()
  def compact(presence_list) do
    # For each user, if ANY device is :online → user is :online
    # Otherwise :away
    # Return %{user_id => %{status: :online | :away, devices: [...]}}
  end
end
```

Presence diffs: Phoenix.Presence already broadcasts only joins/leaves (not full list). We hook into the diff to emit telemetry.

**Day 21 — Presence Integration Tests**

Test:
1. User joins presence channel → appears in presence list
2. User disconnects → removed from presence list
3. User with 2 devices: disconnect one → still shows online
4. User with 2 devices: disconnect both → shows offline
5. Presence diff only contains changes (not full list)
6. Cross-node presence: start 2 nodes, verify presence syncs (use `LocalCluster` for testing)

**Day 22 — Status Updates (Away/Online)**

Handle explicit status changes from clients:

```elixir
@impl true
def handle_in("status:update", %{"status" => status}, socket)
    when status in ["online", "away"] do
  Presence.Tracker.update(socket, socket.assigns.user_id, fn meta ->
    %{meta | status: String.to_existing_atom(status), last_seen: System.system_time(:millisecond)}
  end)
  {:noreply, socket}
end
```

**Day 23 — Presence Telemetry + Cleanup**

- Emit `[:gateway, :presence, :join]` and `[:gateway, :presence, :leave]` telemetry events.
- Add `last_seen` auto-update on any message activity (not just explicit status change).
- Verify presence state is cleaned up on process crash (Phoenix.Presence handles this via process monitoring).

**Day 23 Deliverables Checkpoint:**
- [ ] Phoenix.Presence tracking with per-device metadata
- [ ] Presence compaction (multi-device → single user status)
- [ ] Presence diffs (only changes broadcast)
- [ ] Status updates (online/away)
- [ ] Cross-node presence sync verified
- [ ] Telemetry events for join/leave

---

### Days 24–27: Configuration, Dialyzer, Credo (Hardening)

**Day 24 — Runtime Configuration**

```elixir
# apps/gateway/config/runtime.exs
import Config

config :gateway, Gateway.Endpoint,
  http: [port: System.get_env("PORT") || 4000],
  server: true

config :gateway, Gateway.Auth,
  jwt_secret: System.fetch_env!("JWT_SECRET"),
  token_max_age: String.to_integer(System.get_env("TOKEN_MAX_AGE") || "86400")

config :gateway, Gateway.RateLimiter,
  default_rate: String.to_integer(System.get_env("RATE_LIMIT") || "100"),
  default_burst: String.to_integer(System.get_env("RATE_BURST") || "150")
```

All config via environment variables. No hardcoded secrets.

**Day 25 — Dialyzer + Credo**

- Add `@spec` to every public function in all 3 apps.
- Run `mix dialyzer` — fix all warnings until clean.
- Run `mix credo --strict` — fix all issues until clean.
- Add `@moduledoc` to every module.

**Day 26 — Error Handling Audit**

Review every `handle_in`, `handle_info`, `handle_cast` callback:
- No bare `raise` — use `{:reply, {:error, reason}, socket}` for client errors.
- Log unexpected errors with `Logger.error` + metadata.
- Supervision tree: verify all workers restart correctly after crash.
- Test: kill a ConnectionRegistry, verify it restarts and connections re-register.

**Day 27 — ADR-004**

Write `docs/adr/004-phoenix-pubsub.md`:

```markdown
# ADR-004: Phoenix PubSub over Dedicated Message Broker for Fan-out

## Status: Accepted

## Context
We need to route messages from sender to all channel members. Options:
1. Phoenix.PubSub (built-in, uses :pg2 for distribution)
2. NATS JetStream (dedicated broker)
3. Redpanda/Kafka (durable log)

## Decision
Use Phoenix.PubSub for real-time fan-out within the gateway cluster.
NATS and Redpanda are used in Phase 3 for persistence and cross-service events,
but intra-gateway routing stays on PubSub.

## Consequences
- Easier: Zero additional infrastructure for Phase 2. Sub-millisecond routing.
  Built-in process monitoring for cleanup. Native Elixir — no serialization overhead.
- Harder: PubSub is ephemeral (no replay). Limited to the Elixir cluster.
  Phase 3 adds NATS for durable delivery and cross-service communication.
```

---

### Days 28–30: Load Testing + Final Verification (Step 2.6)

**Day 28 — Load Test Setup**

Create a load test client using `gun` (Erlang HTTP/ client):

```elixir
# tests/load/ws_load_test.exs
defmodule LoadTest.WebSocket do
  @target_connections 10_000  # Start with 10K, scale to 100K
  @messages_per_second 1_000

  def run(num_connections \\ @target_connections) do
    # 1. Spawn num_connections WebSocket clients
    # 2. Each client joins a channel
    # 3. Send messages at configured rate
    # 4. Measure: connection time, message latency, error rate
  end
end
```

Targets (on dev machine — scale to 100K on 16CPU/32GB):
| Metric | Dev Target | Prod Target |
|--------|-----------|-------------|
| Concurrent connections | 10K | 100K |
| Message throughput | 5K msg/sec | 50K msg/sec |
| Presence updates | 1K joins/sec | 10K joins/sec |
| Connection churn | 100/sec | 1K/sec |
| Message routing P99 | <5ms | <5ms |

**Day 29 — Load Test Execution + Profiling**

Run load tests. Profile with:
- `:observer.start()` — verify scheduler utilization, process count, memory
- `:fprof` — identify hot functions
- Telemetry metrics — verify all events fire correctly under load

Fix any bottlenecks found. Common issues:
- ETS contention on rate limiter → use `write_concurrency: true` (already set)
- PubSub bottleneck → verify PG2 distribution is working
- NIF blocking → verify dirty scheduler usage in `:observer`

**Day 30 — Final Verification + Acceptance**

Run the full acceptance checklist:

```bash
# Tests
cd /Users/iyed/Desktop/mercury-messaging
mix test                          # All Elixir tests pass
cargo test --all-features         # All Rust tests still pass (NIF changes)

# Quality
mix dialyzer                      # Zero warnings
mix credo --strict                # Zero issues
mix format --check-formatted      # Formatted
cargo clippy --all-targets --all-features -- -D warnings  # Zero warnings

# Load
mix run tests/load/ws_load_test.exs  # Meets targets
```

---

## Phase 2 Acceptance Criteria

| # | Criterion | Verification |
|---|-----------|-------------|
| 1 | Gateway accepts 100K concurrent WebSocket connections (16CPU/32GB) | Load test |
| 2 | Message routing P99 latency <5ms (gateway only, no DB) | Telemetry metrics |
| 3 | Rust NIFs don't block BEAM scheduler | `:observer` under load |
| 4 | Rate limiting throttles at configured threshold | Integration test |
| 5 | Presence tracking works across 3+ clustered nodes | `LocalCluster` test |
| 6 | Dialyzer specs pass with zero warnings | `mix dialyzer` |
| 7 | Telemetry events fire correctly | Integration test + load test |
| 8 | ADR-004 written | `docs/adr/004-phoenix-pubsub.md` |

---

## File Inventory (New/Modified)

### Rust (modified)
```
crates/mercury-nif/Cargo.toml          — Add rustler, mercury-crdt, mercury-crypto deps
crates/mercury-nif/src/lib.rs          — 9 NIF functions
```

### Elixir (new)
```
apps/gateway/lib/gateway/endpoint.ex           — Phoenix endpoint + WebSocket config
apps/gateway/lib/gateway/mercury_socket.ex     — Socket auth + channel routing
apps/gateway/lib/gateway/message_channel.ex    — Message send/receive channel
apps/gateway/lib/gateway/presence_channel.ex   — Presence tracking channel
apps/gateway/lib/gateway/auth.ex               — JWT verification
apps/gateway/lib/gateway/native.ex             — Rustler NIF wrapper
apps/gateway/lib/gateway/connection_registry.ex — ETS connection registry
apps/gateway/lib/gateway/rate_limiter.ex       — Token bucket rate limiter
apps/gateway/lib/gateway/telemetry.ex          — Telemetry event definitions
apps/gateway/config/runtime.exs                — Runtime configuration

apps/presence/lib/presence/tracker.ex          — Phoenix.Presence implementation
apps/presence/lib/presence/compactor.ex        — Multi-device presence compaction

apps/fanout/lib/fanout/worker.ex               — PubSub consumer (stub for Phase 2)

docs/adr/004-phoenix-pubsub.md                 — ADR: PubSub over broker for fan-out
tests/load/ws_load_test.exs                    — WebSocket load test script
```

### Elixir (modified)
```
mix.exs                                        — Add phoenix deps to umbrella
apps/gateway/mix.exs                           — Add phoenix, rustler, bandit deps
apps/gateway/lib/gateway/application.ex        — Wire supervision tree
apps/presence/mix.exs                          — Add phoenix_pubsub dep
apps/presence/lib/presence/application.ex      — Wire Tracker into supervision tree
apps/fanout/lib/fanout/application.ex          — Wire Worker into supervision tree
```
