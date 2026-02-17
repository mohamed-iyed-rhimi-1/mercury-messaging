import { describe, test, expect } from "bun:test";
import type { LocalStore, QueuedMessage, StoredMessage, SyncState } from "../src/store";
import { OfflineQueue } from "../src/offline-queue";

/** In-memory mock of LocalStore for testing without IndexedDB. */
class MockStore implements Pick<LocalStore, "queueSize" | "dequeue" | "clearQueue" | "enqueue"> {
  private queue: QueuedMessage[] = [];
  private nextId = 1;

  async enqueue(msg: Omit<QueuedMessage, "id">): Promise<void> {
    this.queue.push({ ...msg, id: this.nextId++ });
  }

  async dequeue(count: number): Promise<QueuedMessage[]> {
    return this.queue.slice(0, count);
  }

  async clearQueue(upToId: number): Promise<void> {
    this.queue = this.queue.filter((m) => (m.id ?? 0) > upToId);
  }

  async queueSize(): Promise<number> {
    return this.queue.length;
  }
}

describe("OfflineQueue", () => {
  test("enqueue and drain", async () => {
    const store = new MockStore();
    const queue = new OfflineQueue(store as unknown as LocalStore);

    await queue.enqueue("ch1", "msg:send", { content: "hello" });
    await queue.enqueue("ch1", "msg:send", { content: "world" });

    expect(await queue.size()).toBe(2);

    const items = await queue.drain();
    expect(items.length).toBe(2);
    expect((items[0].payload as { content: string }).content).toBe("hello");
  });

  test("ack removes messages", async () => {
    const store = new MockStore();
    const queue = new OfflineQueue(store as unknown as LocalStore);

    await queue.enqueue("ch1", "msg:send", { content: "a" });
    await queue.enqueue("ch1", "msg:send", { content: "b" });
    await queue.enqueue("ch1", "msg:send", { content: "c" });

    const items = await queue.drain();
    // ACK first two
    await queue.ack(items[1].id!);

    expect(await queue.size()).toBe(1);
    const remaining = await queue.drain();
    expect((remaining[0].payload as { content: string }).content).toBe("c");
  });
});
