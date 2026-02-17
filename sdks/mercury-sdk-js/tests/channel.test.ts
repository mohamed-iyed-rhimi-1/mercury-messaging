import { describe, test, expect } from "bun:test";
import { Channel } from "../src/channel";
import { encodeEnvelope, encodeTyping } from "../src/codec";
import { EV_MSG_SEND, EV_MSG_HISTORY, EV_MSG_NEW, EV_MSG_TYPING, EV_MSG_READ, EV_SYNC_REQUEST, EV_SYNC_PUSH, packEnvelopes } from "../src/frame";
import type { BinaryTransport } from "../src/transport";
import type { Message } from "../src/types";

/** Mock transport that simulates binary WebSocket replies. */
function createMockTransport() {
  const handlers = new Map<number, Map<number, (payload: Uint8Array) => void>>();
  let joinedTopics: string[] = [];
  let nextTopicId = 1;
  const topicMap = new Map<string, number>();

  return {
    join: async (topic: string) => {
      joinedTopics.push(topic);
      const id = nextTopicId++;
      topicMap.set(topic, id);
    },
    push: async (_topic: string, event: number, _payload: Uint8Array): Promise<Uint8Array> => {
      if (event === EV_MSG_SEND) return new Uint8Array(16); // msg ID
      if (event === EV_MSG_HISTORY) return packEnvelopes([]); // empty history
      if (event === EV_MSG_READ) return new Uint8Array(0);
      if (event === EV_SYNC_REQUEST) {
        // <<server_hlc:64LE, has_more:8, packed(0)>>
        const buf = new Uint8Array(9 + 4);
        const v = new DataView(buf.buffer);
        v.setBigUint64(0, 1000n, true);
        buf[8] = 0; // has_more = false
        v.setUint32(9, 0, true); // count = 0
        return buf;
      }
      if (event === EV_SYNC_PUSH) {
        // <<accepted:32LE, server_hlc:64LE>>
        const buf = new Uint8Array(12);
        const v = new DataView(buf.buffer);
        v.setUint32(0, 0, true);
        v.setBigUint64(4, 1000n, true);
        return buf;
      }
      return new Uint8Array(0);
    },
    on: (topicId: number, event: number, cb: (payload: Uint8Array) => void) => {
      if (!handlers.has(topicId)) handlers.set(topicId, new Map());
      handlers.get(topicId)!.set(event, cb);
    },
    onByName: (topic: string, event: number, cb: (payload: Uint8Array) => void) => {
      const id = topicMap.get(topic);
      if (id !== undefined) {
        if (!handlers.has(id)) handlers.set(id, new Map());
        handlers.get(id)!.set(event, cb);
      }
    },
    off: () => {},
    isConnected: () => true,
    onReconnect: () => {},
    getTopicId: (topic: string) => topicMap.get(topic),
    // Test helper: emit a broadcast event
    _emit: (topic: string, event: number, payload: Uint8Array) => {
      const id = topicMap.get(topic);
      if (id !== undefined) handlers.get(id)?.get(event)?.(payload);
    },
    _joinedTopics: () => joinedTopics,
  };
}

describe("Channel", () => {
  test("join subscribes to topic", async () => {
    const transport = createMockTransport();
    const channel = new Channel(transport as unknown as BinaryTransport, "general", new Uint8Array(16), new Uint8Array(16));
    await channel.join();
    expect(transport._joinedTopics()).toContain("channel:general");
  });

  test("send returns message id", async () => {
    const transport = createMockTransport();
    const channel = new Channel(transport as unknown as BinaryTransport, "general", new Uint8Array(16), new Uint8Array(16));
    await channel.join();
    const result = await channel.send("hello");
    expect(result.id).toBeDefined();
    expect(result.id.length).toBe(32); // 16 bytes hex
  });

  test("history returns messages", async () => {
    const transport = createMockTransport();
    const channel = new Channel(transport as unknown as BinaryTransport, "general", new Uint8Array(16), new Uint8Array(16));
    await channel.join();
    const result = await channel.history({ limit: 10 });
    expect(result.messages).toEqual([]);
  });

  test("on message receives incoming messages", async () => {
    const transport = createMockTransport();
    const channel = new Channel(transport as unknown as BinaryTransport, "general", new Uint8Array(16), new Uint8Array(16));

    const received: Message[] = [];
    channel.on("message", (msg) => received.push(msg));
    await channel.join();

    const senderId = new Uint8Array(16); senderId[0] = 0x01;
    const msgId = new Uint8Array(16); msgId[0] = 0x02;
    const envelope = encodeEnvelope({
      tenantId: new Uint8Array(16),
      channelId: new Uint8Array(16),
      senderId, messageId: msgId,
      timestamp: BigInt(Date.now()),
      payload: new TextEncoder().encode("hello"),
    });

    // Binary transport emits raw capnp bytes, not base64
    transport._emit("channel:general", EV_MSG_NEW, envelope);

    expect(received.length).toBe(1);
    expect(received[0].content).toBe("hello");
  });

  test("on typing receives typing indicators", async () => {
    const transport = createMockTransport();
    const channel = new Channel(transport as unknown as BinaryTransport, "general", new Uint8Array(16), new Uint8Array(16));

    const typings: { userId: string }[] = [];
    channel.on("typing", (data) => typings.push(data));
    await channel.join();

    const uid = new Uint8Array(16); uid[0] = 0x01;
    const bin = encodeTyping(uid);
    // Raw bytes, no base64
    transport._emit("channel:general", EV_MSG_TYPING, bin);
    expect(typings.length).toBe(1);
  });

  test("markRead sends read receipt", async () => {
    const transport = createMockTransport();
    const channel = new Channel(transport as unknown as BinaryTransport, "general", new Uint8Array(16), new Uint8Array(16));
    await channel.join();
    await channel.markRead("00".repeat(16));
  });

  test("sync fetches deltas from server", async () => {
    const transport = createMockTransport();
    const channel = new Channel(transport as unknown as BinaryTransport, "general", new Uint8Array(16), new Uint8Array(16));
    await channel.join();
    const result = await channel.sync(0);
    expect(result.deltas).toEqual([]);
    expect(result.serverHlc).toBe(1000);
    expect(result.hasMore).toBe(false);
  });

  test("pushDeltas sends offline queue", async () => {
    const transport = createMockTransport();
    const channel = new Channel(transport as unknown as BinaryTransport, "general", new Uint8Array(16), new Uint8Array(16));
    await channel.join();
    const result = await channel.pushDeltas([{ type: "MessageAppend" }]);
    expect(result.accepted).toBe(0);
  });
});
