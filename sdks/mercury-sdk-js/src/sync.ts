/**
 * Delta sync engine: coordinates sync on reconnect.
 *
 * Flow:
 * 1. On reconnect, fetch deltas from server since last known HLC
 * 2. Merge into local store
 * 3. Push offline queue to server
 * 4. Update sync cursor
 */

import type { LocalStore, StoredMessage } from "./store";
import type { Channel } from "./channel";
import { OfflineQueue } from "./offline-queue";

export class SyncEngine {
  private queue: OfflineQueue;

  constructor(private store: LocalStore) {
    this.queue = new OfflineQueue(store);
  }

  /** Full sync cycle for a channel after reconnect. */
  async syncChannel(channel: Channel, channelId: string): Promise<{
    received: number;
    pushed: number;
  }> {
    // 1. Pull: fetch server deltas since our last known HLC
    const syncState = await this.store.getSyncState(channelId);
    const lastWall = syncState?.lastHlcWall ?? 0;

    let received = 0;
    let hasMore = true;
    let currentWall = lastWall;

    while (hasMore) {
      const result = await channel.sync(currentWall);
      hasMore = result.hasMore;
      currentWall = result.serverHlc;

      // Store received deltas as messages
      for (const delta of result.deltas) {
        const d = delta as Record<string, unknown>;
        if (d.type === "MessageAppend") {
          await this.store.writeMessage({
            channelId,
            messageId: d.message_id as string,
            sender: d.sender_id as string,
            content: d.encrypted_content as string,
            contentType: d.content_type as number,
            timestamp: (d.hlc as Record<string, number>)?.wall_clock_ms ?? Date.now(),
          });
          received += 1;
        }
      }
    }

    // Update sync state
    if (currentWall > lastWall) {
      await this.store.setSyncState(channelId, currentWall);
    }

    // 2. Push: drain offline queue
    let pushed = 0;
    const pending = await this.queue.drain();
    const channelDeltas = pending.filter((m) => m.channelId === channelId);

    if (channelDeltas.length > 0) {
      const deltas = channelDeltas.map((m) => m.payload);
      const result = await channel.pushDeltas(deltas);
      pushed = result.accepted;

      // ACK the pushed messages
      const lastId = channelDeltas[channelDeltas.length - 1].id;
      if (lastId != null) {
        await this.queue.ack(lastId);
      }
    }

    // Evict old messages if over limit
    await this.store.evictOldMessages(channelId);

    return { received, pushed };
  }

  /** Queue a message for offline delivery. */
  async queueOffline(
    channelId: string,
    event: string,
    payload: unknown,
  ): Promise<void> {
    await this.queue.enqueue(channelId, event, payload);
  }

  /** Get the offline queue instance. */
  getQueue(): OfflineQueue {
    return this.queue;
  }
}
