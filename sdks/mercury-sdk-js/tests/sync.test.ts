import { describe, test, expect, mock } from "bun:test";
import { SyncEngine } from "../src/sync";
import type { LocalStore, QueuedMessage, SyncState, StoredMessage } from "../src/store";
import type { Channel } from "../src/channel";

/** Minimal mock store for sync engine tests. */
function createMockStore() {
  const messages: StoredMessage[] = [];
  const syncStates = new Map<string, SyncState>();
  const queue: QueuedMessage[] = [];
  let nextId = 1;

  return {
    messages,
    queue,
    async writeMessage(msg: StoredMessage) { messages.push(msg); },
    async readMessages() { return messages; },
    async getSyncState(channelId: string) { return syncStates.get(channelId); },
    async setSyncState(channelId: string, lastHlcWall: number) {
      syncStates.set(channelId, { channelId, lastHlcWall });
    },
    async enqueue(msg: Omit<QueuedMessage, "id">) {
      queue.push({ ...msg, id: nextId++ });
    },
    async dequeue(count: number) { return queue.slice(0, count); },
    async clearQueue(upToId: number) {
      const idx = queue.findIndex((m) => (m.id ?? 0) > upToId);
      queue.splice(0, idx === -1 ? queue.length : idx);
    },
    async queueSize() { return queue.length; },
    async evictOldMessages() { return 0; },
    async close() {},
  } as unknown as LocalStore;
}

describe("SyncEngine", () => {
  test("syncChannel pulls deltas and updates sync state", async () => {
    const store = createMockStore();
    const engine = new SyncEngine(store);

    const mockChannel = {
      sync: mock(async () => ({
        deltas: [
          {
            type: "MessageAppend",
            message_id: "msg1",
            sender_id: "user1",
            encrypted_content: "hello",
            content_type: 0,
            hlc: { wall_clock_ms: 1000 },
          },
        ],
        serverHlc: 2000,
        hasMore: false,
      })),
      pushDeltas: mock(async () => ({ accepted: 0, serverHlc: 2000 })),
    } as unknown as Channel;

    const result = await engine.syncChannel(mockChannel, "ch1");

    expect(result.received).toBe(1);
    expect(result.pushed).toBe(0);
    expect(mockChannel.sync).toHaveBeenCalledWith(0); // first sync, no prior state

    // Verify sync state was updated
    const state = await store.getSyncState("ch1");
    expect(state?.lastHlcWall).toBe(2000);
  });

  test("syncChannel pushes offline queue", async () => {
    const store = createMockStore();
    const engine = new SyncEngine(store);

    // Queue an offline message
    await engine.queueOffline("ch1", "msg:send", { content: "offline msg" });

    const mockChannel = {
      sync: mock(async () => ({
        deltas: [],
        serverHlc: 1000,
        hasMore: false,
      })),
      pushDeltas: mock(async () => ({ accepted: 1, serverHlc: 1500 })),
    } as unknown as Channel;

    const result = await engine.syncChannel(mockChannel, "ch1");

    expect(result.pushed).toBe(1);
    expect(mockChannel.pushDeltas).toHaveBeenCalled();

    // Queue should be drained
    const remaining = await engine.getQueue().size();
    expect(remaining).toBe(0);
  });

  test("queueOffline stores messages", async () => {
    const store = createMockStore();
    const engine = new SyncEngine(store);

    await engine.queueOffline("ch1", "msg:send", { content: "a" });
    await engine.queueOffline("ch1", "msg:send", { content: "b" });

    const size = await engine.getQueue().size();
    expect(size).toBe(2);
  });
});
