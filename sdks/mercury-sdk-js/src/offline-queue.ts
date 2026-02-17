/**
 * Offline queue: buffers outbound messages when disconnected.
 * Drains in order on reconnect via sync:push.
 *
 * Bounded: max 10,000 pending messages (NASA Rule #2).
 */

import type { LocalStore, QueuedMessage } from "./store";

const MAX_QUEUE_SIZE = 10_000;
const DRAIN_BATCH_SIZE = 100;

export class OfflineQueue {
  constructor(private store: LocalStore) {}

  /** Queue a message for later delivery. Drops oldest if at capacity. */
  async enqueue(
    channelId: string,
    event: string,
    payload: unknown,
  ): Promise<void> {
    const size = await this.store.queueSize();
    if (size >= MAX_QUEUE_SIZE) {
      // Evict oldest batch to make room
      const oldest = await this.store.dequeue(1);
      if (oldest.length > 0 && oldest[0].id != null) {
        await this.store.clearQueue(oldest[0].id);
      }
    }
    await this.store.enqueue({
      channelId,
      event,
      payload,
      createdAt: Date.now(),
    });
  }

  /** Drain queued messages in batches. Returns items to send. */
  async drain(): Promise<QueuedMessage[]> {
    return this.store.dequeue(DRAIN_BATCH_SIZE);
  }

  /** Acknowledge successful delivery up to a given queue ID. */
  async ack(upToId: number): Promise<void> {
    await this.store.clearQueue(upToId);
  }

  /** Number of pending messages. */
  async size(): Promise<number> {
    return this.store.queueSize();
  }
}
