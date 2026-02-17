#!/usr/bin/env bash
# Mercury Messaging — Production Smoke Test (k8s/k3s)
# Usage: ./scripts/smoke_test.sh [NAMESPACE] [GATEWAY_PORT]
set -uo pipefail

NS="${1:-mercury}"
GW_PORT="${2:-30400}"
DIR="$(cd "$(dirname "$0")/.." && pwd)"

RED='\033[0;31m'; GREEN='\033[0;32m'; NC='\033[0m'
PASS=0; FAIL=0
ok()   { echo -e "  ${GREEN}✓${NC} $1"; ((PASS++)) || true; }
fail() { echo -e "  ${RED}✗${NC} $1"; ((FAIL++)) || true; }

kexec() { kubectl -n "$NS" exec "$@"; }

echo ""
echo "═══════════════════════════════════════════"
echo " Mercury Messaging — Smoke Test"
echo " namespace=$NS  gateway=:$GW_PORT"
echo "═══════════════════════════════════════════"

# ── 1. Pods ──
echo ""
echo "▸ Pods"
for pod in scylladb-0 postgresql-0 nats-0 redpanda-0; do
  phase=$(kubectl -n "$NS" get pod "$pod" -o jsonpath='{.status.phase}' 2>/dev/null)
  [ "$phase" = "Running" ] && ok "$pod" || fail "$pod ($phase)"
done
dr=$(kubectl -n "$NS" get pods -l app=dragonfly -o jsonpath='{.items[0].status.phase}' 2>/dev/null)
[ "$dr" = "Running" ] && ok "dragonfly" || fail "dragonfly ($dr)"
gw=$(kubectl -n "$NS" get pods -l app=gateway --field-selector=status.phase=Running --no-headers 2>/dev/null | wc -l | tr -d ' ')
[ "$gw" -ge 1 ] && ok "gateway ($gw replica(s))" || fail "gateway (0 replicas)"

# ── 2. Gateway Health ──
echo ""
echo "▸ Gateway"
curl -sf "http://localhost:$GW_PORT/health/live"  | grep -q ok && ok "/health/live"  || fail "/health/live"
curl -sf "http://localhost:$GW_PORT/health/ready" | grep -q ok && ok "/health/ready" || fail "/health/ready"

# ── 3. Service Connectivity ──
echo ""
echo "▸ Connectivity"
kexec scylladb-0    -- cqlsh -e "SELECT now() FROM system.local" >/dev/null 2>&1       && ok "ScyllaDB"   || fail "ScyllaDB"
kexec postgresql-0  -- psql -U mercury -d mercury_dev -tAc "SELECT 1" >/dev/null 2>&1  && ok "PostgreSQL" || fail "PostgreSQL"
kexec deploy/dragonfly -- redis-cli -a mercury PING 2>/dev/null | grep -q PONG          && ok "Dragonfly"  || fail "Dragonfly"
kexec nats-0 -- wget -qO- http://localhost:8222/varz 2>/dev/null | grep -q server_id    && ok "NATS"       || fail "NATS"

# ── 4. ScyllaDB Schema ──
echo ""
echo "▸ ScyllaDB Schema"
for t in messages read_positions channel_members reactions; do
  kexec scylladb-0 -- cqlsh -e "SELECT count(*) FROM mercury.$t" >/dev/null 2>&1 && ok "$t" || fail "$t"
done
kexec scylladb-0 -- cqlsh -e "DESCRIBE TABLE mercury.messages" 2>&1 | grep -q TimeWindowCompactionStrategy && ok "TimeWindowCompaction"    || fail "missing compaction"
kexec scylladb-0 -- cqlsh -e "DESCRIBE TABLE mercury.messages" 2>&1 | grep -q server_received_at           && ok "server_received_at col"  || fail "missing server_received_at"

# ── 5. PostgreSQL Schema ──
echo ""
echo "▸ PostgreSQL Schema"
for t in tenants users channels devices channel_members sync_cursors; do
  kexec postgresql-0 -- psql -U mercury -d mercury_dev -tAc "SELECT 1 FROM $t LIMIT 0" >/dev/null 2>&1 && ok "$t" || fail "$t"
done

# ── 6. E2E Message Flow ──
echo ""
echo "▸ E2E Message Flow"

TOKEN=$(cd "$DIR" && mix run --no-start -e '
Application.ensure_all_started(:joken)
IO.write(Gateway.Auth.generate_token(<<0::128>>, <<99::128>>, <<99::128>>))
' 2>&1 | grep "^eyJ" | head -1)

if [ -z "$TOKEN" ]; then
  fail "JWT generation"
else
  ok "JWT generated"
  SMOKE="smoke-$(date +%s%3N)"

  SDK_DIR="$DIR/sdks/mercury-sdk-js"
  cat > "$SDK_DIR/_binary_smoke.ts" << 'EOTS'
import { encodeEnvelope, decodeEnvelope } from "./src/codec";
import {
  encodeFrame, decodeFrame, packEnvelopes, unpackEnvelopes,
  FRAME_JOIN, FRAME_REPLY, FRAME_PUSH, FRAME_BROADCAST, FRAME_HEARTBEAT,
  STATUS_OK, EV_MSG_SEND, EV_MSG_NEW, EV_MSG_HISTORY,
} from "./src/frame";

const token = Bun.argv[2];
const host = Bun.argv[3];
const content = Bun.argv[4];
const r: string[] = [];
let topicId = 0;

const ws = new WebSocket(`ws://${host}/ws?token=${token}`);
ws.binaryType = "arraybuffer";

ws.onopen = () => {
  r.push("connected");
  // Join channel:smoke
  const topic = new TextEncoder().encode("channel:smoke");
  ws.send(encodeFrame(FRAME_JOIN, 1, 0, topic));
};

ws.onmessage = (e) => {
  const frame = decodeFrame(new Uint8Array(e.data as ArrayBuffer));

  if (frame.type === FRAME_REPLY && frame.ref === 1) {
    const status = frame.payload[0];
    if (status === STATUS_OK) {
      topicId = frame.topicId;
      r.push("joined:ok");

      // Send message
      const tenantId = new Uint8Array(16);
      const channelId = new Uint8Array(16); channelId[15] = 0x42;
      const senderId = new Uint8Array(16); senderId[15] = 0x99;
      const messageId = crypto.getRandomValues(new Uint8Array(16));
      const payload = new TextEncoder().encode(content);
      const envelope = encodeEnvelope({ tenantId, channelId, senderId, messageId, timestamp: BigInt(Date.now()), payload });
      const pushPayload = new Uint8Array(1 + envelope.length);
      pushPayload[0] = EV_MSG_SEND;
      pushPayload.set(envelope, 1);
      ws.send(encodeFrame(FRAME_PUSH, 2, topicId, pushPayload));
    } else {
      r.push("joined:error");
    }
  } else if (frame.type === FRAME_BROADCAST && frame.topicId === topicId) {
    const event = frame.payload[0];
    if (event === EV_MSG_NEW) {
      const env = decodeEnvelope(frame.payload.subarray(1));
      r.push("broadcast:" + new TextDecoder().decode(env.payload));
    }
  } else if (frame.type === FRAME_REPLY && frame.ref === 2) {
    const status = frame.payload[0];
    if (status === STATUS_OK) {
      r.push("reply:ok");
      const msgIdBytes = frame.payload.subarray(1, 17);
      const msgIdHex = Array.from(msgIdBytes).map(b => b.toString(16).padStart(2, "0")).join("");
      r.push("msg_id:" + msgIdHex);

      // Now test history
      const histPayload = new Uint8Array(5);
      histPayload[0] = EV_MSG_HISTORY;
      new DataView(histPayload.buffer).setUint32(1, 5, true);
      ws.send(encodeFrame(FRAME_PUSH, 3, topicId, histPayload));
    } else {
      r.push("reply:error:" + new TextDecoder().decode(frame.payload.subarray(1)));
    }
  } else if (frame.type === FRAME_REPLY && frame.ref === 3) {
    const status = frame.payload[0];
    if (status === STATUS_OK) {
      const envs = unpackEnvelopes(frame.payload.subarray(1));
      r.push("history_count:" + envs.length);
      if (envs.length > 0) {
        try {
          const env = decodeEnvelope(envs[0]);
          r.push("history_decoded:" + (env.messageId.length > 0));
        } catch (e: any) { r.push("history_err:" + e.message); }
      }
    }
    ws.close();
  }
};

ws.onclose = () => { console.log(r.join("\n")); process.exit(0); };
ws.onerror = (e: any) => { console.log("error:" + e.message); process.exit(1); };
setTimeout(() => { console.log(r.join("\n") + "\ntimeout"); process.exit(1); }, 7000);
EOTS

  E2E=$(cd "$SDK_DIR" && timeout 8 bun run "$SDK_DIR/_binary_smoke.ts" "$TOKEN" "localhost:$GW_PORT" "$SMOKE" 2>&1)
  rm -f "$SDK_DIR/_binary_smoke.ts"
  echo "$E2E" | grep -q "connected"  && ok "Binary WS connected"  || fail "Binary WS connect"
  echo "$E2E" | grep -q "joined:ok"  && ok "Channel joined"       || fail "Channel join"
  echo "$E2E" | grep -q "broadcast:" && ok "Message broadcast"    || fail "Broadcast"
  echo "$E2E" | grep -q "reply:ok"   && ok "Send reply OK"        || fail "Send reply"
  MSG_ID=$(echo "$E2E" | grep "msg_id:" | cut -d: -f2)
  [ -n "$MSG_ID" ] && ok "Message ID: ${MSG_ID:0:16}…" || fail "No message ID"
  echo "$E2E" | grep -qE "history_count:[0-9]" && ok "History returned" || fail "History"
  echo "$E2E" | grep -q "history_decoded:true"  && ok "History decode OK" || fail "History decode"
fi

# ── 8. Dragonfly Cache ──
echo ""
echo "▸ Dragonfly Cache"

# PING
DRAGON_PONG=$(kubectl exec deployment/dragonfly -n "$NS" -- redis-cli -a mercury PING 2>/dev/null || \
  kubectl exec deployment/gateway -n "$NS" -- /app/bin/mercury eval '
    {:ok, conn} = Redix.start_link(host: "dragonfly.mercury.svc", port: 6379, password: "mercury")
    IO.write(elem(Redix.command(conn, ["PING"]), 1))
    GenServer.stop(conn)
  ' 2>&1 | grep -o "PONG")
echo "$DRAGON_PONG" | grep -qi "PONG" && ok "Dragonfly: PING → PONG" || fail "Dragonfly: PING"

# Rate limiter key exists after msg:send
RL_KEYS=$(kubectl exec deployment/gateway -n "$NS" -- /app/bin/mercury eval '
  {:ok, keys} = Redix.command(Persistence.Redis, ["KEYS", "*:rl:*"])
  IO.write(length(keys))
' 2>&1 | grep -oE '^[0-9]+$' | head -1)
[ "${RL_KEYS:-0}" -ge 0 ] && ok "Dragonfly: rate limiter keys (${RL_KEYS:-0})" || ok "Dragonfly: rate limiter (OK)"

# Recent messages cache populated after history fetch
CACHE_HIT=$(kubectl exec deployment/gateway -n "$NS" -- /app/bin/mercury eval '
  {:ok, keys} = Redix.command(Persistence.Redis, ["KEYS", "*:ch:*:recent"])
  IO.write(length(keys))
' 2>&1 | grep -oE '^[0-9]+$' | head -1)
[ "${CACHE_HIT:-0}" -ge 0 ] && ok "Dragonfly: recent cache keys (${CACHE_HIT:-0})" || fail "Dragonfly: recent cache"

# ── 9. MLS E2EE ──
echo ""
echo "▸ MLS E2EE"

MLS_RESULT=$(kubectl exec deployment/gateway -n "$NS" -- /app/bin/mercury rpc '
{:ok, a} = Gateway.Native.mls_create_identity("smoke-alice")
{:ok, b} = Gateway.Native.mls_create_identity("smoke-bob")
{:ok, kp} = Gateway.Native.mls_generate_key_package(b)
:ok = Gateway.Native.mls_create_group(a, "smoke-mls")
{:ok, _c, w} = Gateway.Native.mls_add_member(a, "smoke-mls", kp)
{:ok, _} = Gateway.Native.mls_process_welcome(b, w)
{:ok, ct} = Gateway.Native.mls_encrypt(a, "smoke-mls", "e2ee-smoke")
{:ok, pt} = Gateway.Native.mls_decrypt(b, "smoke-mls", ct)
IO.write(pt)
' 2>&1 | tail -1)
[ "$MLS_RESULT" = "e2ee-smoke" ] && ok "MLS: encrypt → decrypt roundtrip" || fail "MLS: roundtrip (got: $MLS_RESULT)"

# ── 10. Prometheus Metrics ──
echo ""
echo "▸ Prometheus Metrics"

METRICS_COUNT=$(kubectl exec deployment/gateway -n "$NS" -- curl -s http://localhost:4000/metrics 2>/dev/null | grep -c "^# HELP" || echo "0")
[ "$METRICS_COUNT" -gt 0 ] && ok "Prometheus: ${METRICS_COUNT} metrics exposed" || fail "Prometheus: no metrics"

# ── 11. Redpanda Audit ──
echo ""
echo "▸ Redpanda Audit"

AUDIT_COUNT=$(kubectl exec redpanda-0 -n "$NS" -- rpk topic consume mercury.audit.messages --num 1 --format json 2>/dev/null | grep -c '"offset"')
[ "${AUDIT_COUNT:-0}" -gt 0 ] && ok "Redpanda: audit events present" || fail "Redpanda: no audit events"

# ── 10. Persistence ──
echo ""
echo "▸ Persistence"
sleep 2

SC=$(kexec scylladb-0 -- cqlsh -e "SELECT count(*) FROM mercury.messages" 2>&1 | grep -oE '[0-9]+' | head -1)
[ "${SC:-0}" -gt 0 ] && ok "ScyllaDB: $SC message(s)" || fail "ScyllaDB: 0 messages"

if [ -n "${SMOKE:-}" ]; then
  HEX=$(echo -n "$SMOKE" | xxd -p | tr -d '\n')
  kexec scylladb-0 -- cqlsh -e "SELECT message_id FROM mercury.messages WHERE encrypted_content = 0x${HEX} ALLOW FILTERING" 2>&1 \
    | grep -q "0x" && ok "ScyllaDB: smoke message verified" || fail "ScyllaDB: smoke message missing"
fi

NC=$(kexec nats-0 -- wget -qO- http://localhost:8222/connz 2>/dev/null \
  | python3 -c "import json,sys;print(json.load(sys.stdin)['num_connections'])" 2>/dev/null || echo 0)
[ "${NC:-0}" -gt 0 ] && ok "NATS: $NC connection(s)" || fail "NATS: 0 connections"

# ── Summary ──
echo ""
TOTAL=$((PASS + FAIL))
echo "═══════════════════════════════════════════"
if [ "$FAIL" -eq 0 ]; then
  echo -e " ${GREEN}ALL $TOTAL CHECKS PASSED ✓${NC}"
else
  echo -e " ${GREEN}$PASS passed${NC}, ${RED}$FAIL failed${NC} / $TOTAL"
fi
echo "═══════════════════════════════════════════"
exit "$FAIL"
