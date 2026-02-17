// Mercury Gateway load test — k6 WebSocket
// Usage: k6 run --vus 100 --duration 60s tests/load.js
//
// Targets (single node, 4 CPU / 8GB):
//   10K concurrent connections
//   5K msg/sec sustained
//   P99 message delivery <100ms

import ws from "k6/ws";
import { check, sleep } from "k6";
import { Counter, Trend } from "k6/metrics";

const GATEWAY_URL = __ENV.GATEWAY_URL || "ws://localhost:4000/ws";
const TOKEN = __ENV.TOKEN || "test-token";

const msgSent = new Counter("messages_sent");
const msgReceived = new Counter("messages_received");
const msgLatency = new Trend("message_latency_ms");

export const options = {
  scenarios: {
    sustained: {
      executor: "constant-vus",
      vus: 100,
      duration: "60s",
    },
  },
  thresholds: {
    message_latency_ms: ["p(99)<100"],
    messages_sent: ["count>1000"],
  },
};

export default function () {
  const url = `${GATEWAY_URL}?token=${TOKEN}&vsn=2.0.0`;

  const res = ws.connect(url, {}, function (socket) {
    let ref = 0;
    const nextRef = () => String(++ref);

    // Join channel
    socket.send(
      JSON.stringify([
        nextRef(),
        nextRef(),
        "channel:loadtest",
        "phx_join",
        {},
      ]),
    );

    // Listen for messages
    socket.on("message", (data) => {
      const msg = JSON.parse(data);
      if (msg[3] === "msg:new") {
        msgReceived.add(1);
        const payload = msg[4];
        if (payload && payload.ts) {
          msgLatency.add(Date.now() - payload.ts);
        }
      }
    });

    // Send messages every 200ms
    for (let i = 0; i < 5; i++) {
      const r = nextRef();
      socket.send(
        JSON.stringify([
          null,
          r,
          "channel:loadtest",
          "msg:send",
          { content: `load-test-${__VU}-${i}`, content_type: 0 },
        ]),
      );
      msgSent.add(1);
      sleep(0.2);
    }

    // Heartbeat
    socket.send(JSON.stringify([null, nextRef(), "phoenix", "heartbeat", {}]));

    sleep(1);
    socket.close();
  });

  check(res, {
    "WebSocket connected": (r) => r && r.status === 101,
  });
}
