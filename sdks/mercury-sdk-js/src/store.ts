/**
 * IndexedDB local storage for offline-first messaging.
 * Stores messages, sync state, and offline queue.
 *
 * Bounded: max 10,000 messages per channel (NASA Rule #2).
 */

const DB_NAME = "mercury";
const DB_VERSION = 1;
const MAX_MESSAGES_PER_CHANNEL = 10_000;

export interface StoredMessage {
  channelId: string;
  messageId: string;
  sender: string;
  content: string;
  contentType: number;
  timestamp: number;
}

export interface SyncState {
  channelId: string;
  lastHlcWall: number;
}

export interface QueuedMessage {
  id?: number; // auto-increment key
  channelId: string;
  event: string;
  payload: unknown;
  createdAt: number;
}

function openDb(): Promise<IDBDatabase> {
  return new Promise((resolve, reject) => {
    const req = indexedDB.open(DB_NAME, DB_VERSION);

    req.onupgradeneeded = () => {
      const db = req.result;

      if (!db.objectStoreNames.contains("messages")) {
        const msgStore = db.createObjectStore("messages", {
          keyPath: ["channelId", "messageId"],
        });
        msgStore.createIndex("byChannel", "channelId");
        msgStore.createIndex("byTimestamp", ["channelId", "timestamp"]);
      }

      if (!db.objectStoreNames.contains("syncState")) {
        db.createObjectStore("syncState", { keyPath: "channelId" });
      }

      if (!db.objectStoreNames.contains("offlineQueue")) {
        db.createObjectStore("offlineQueue", {
          keyPath: "id",
          autoIncrement: true,
        });
      }
    };

    req.onsuccess = () => resolve(req.result);
    req.onerror = () => reject(req.error);
  });
}

/** Wrap an IDB request in a Promise. */
function reqToPromise<T>(req: IDBRequest<T>): Promise<T> {
  return new Promise((resolve, reject) => {
    req.onsuccess = () => resolve(req.result);
    req.onerror = () => reject(req.error);
  });
}

export class LocalStore {
  private dbPromise: Promise<IDBDatabase>;

  constructor() {
    this.dbPromise = openDb();
  }

  // ── Messages ──

  async writeMessage(msg: StoredMessage): Promise<void> {
    const db = await this.dbPromise;
    const tx = db.transaction("messages", "readwrite");
    tx.objectStore("messages").put(msg);
    await new Promise<void>((resolve, reject) => {
      tx.oncomplete = () => resolve();
      tx.onerror = () => reject(tx.error);
    });
  }

  async readMessages(
    channelId: string,
    limit = 50,
  ): Promise<StoredMessage[]> {
    const db = await this.dbPromise;
    const tx = db.transaction("messages", "readonly");
    const index = tx.objectStore("messages").index("byTimestamp");

    // Range: all entries for this channel, iterate backwards (newest first)
    const range = IDBKeyRange.bound(
      [channelId, 0],
      [channelId, Number.MAX_SAFE_INTEGER],
    );

    return new Promise((resolve, reject) => {
      const results: StoredMessage[] = [];
      const req = index.openCursor(range, "prev");

      req.onsuccess = () => {
        const cursor = req.result;
        if (cursor && results.length < limit) {
          results.push(cursor.value as StoredMessage);
          cursor.continue();
        } else {
          resolve(results);
        }
      };
      req.onerror = () => reject(req.error);
    });
  }

  /** Evict oldest messages if channel exceeds max. */
  async evictOldMessages(channelId: string): Promise<number> {
    const db = await this.dbPromise;
    const tx = db.transaction("messages", "readwrite");
    const index = tx.objectStore("messages").index("byTimestamp");
    const store = tx.objectStore("messages");

    const range = IDBKeyRange.bound(
      [channelId, 0],
      [channelId, Number.MAX_SAFE_INTEGER],
    );

    return new Promise((resolve, reject) => {
      const countReq = index.count(range);
      countReq.onsuccess = () => {
        const total = countReq.result;
        const toDelete = total - MAX_MESSAGES_PER_CHANNEL;
        if (toDelete <= 0) {
          resolve(0);
          return;
        }

        // Delete oldest entries
        let deleted = 0;
        const cursorReq = index.openCursor(range, "next");
        cursorReq.onsuccess = () => {
          const cursor = cursorReq.result;
          if (cursor && deleted < toDelete) {
            store.delete(cursor.primaryKey);
            deleted += 1;
            cursor.continue();
          } else {
            resolve(deleted);
          }
        };
        cursorReq.onerror = () => reject(cursorReq.error);
      };
      countReq.onerror = () => reject(countReq.error);
    });
  }

  // ── Sync State ──

  async getSyncState(channelId: string): Promise<SyncState | undefined> {
    const db = await this.dbPromise;
    const tx = db.transaction("syncState", "readonly");
    const result = await reqToPromise(
      tx.objectStore("syncState").get(channelId),
    );
    return result as SyncState | undefined;
  }

  async setSyncState(channelId: string, lastHlcWall: number): Promise<void> {
    const db = await this.dbPromise;
    const tx = db.transaction("syncState", "readwrite");
    tx.objectStore("syncState").put({ channelId, lastHlcWall });
    await new Promise<void>((resolve, reject) => {
      tx.oncomplete = () => resolve();
      tx.onerror = () => reject(tx.error);
    });
  }

  // ── Offline Queue ──

  async enqueue(msg: Omit<QueuedMessage, "id">): Promise<void> {
    const db = await this.dbPromise;
    const tx = db.transaction("offlineQueue", "readwrite");
    tx.objectStore("offlineQueue").add(msg);
    await new Promise<void>((resolve, reject) => {
      tx.oncomplete = () => resolve();
      tx.onerror = () => reject(tx.error);
    });
  }

  async dequeue(count = 100): Promise<QueuedMessage[]> {
    const db = await this.dbPromise;
    const tx = db.transaction("offlineQueue", "readonly");
    const store = tx.objectStore("offlineQueue");

    return new Promise((resolve, reject) => {
      const results: QueuedMessage[] = [];
      const req = store.openCursor();

      req.onsuccess = () => {
        const cursor = req.result;
        if (cursor && results.length < count) {
          results.push(cursor.value as QueuedMessage);
          cursor.continue();
        } else {
          resolve(results);
        }
      };
      req.onerror = () => reject(req.error);
    });
  }

  async clearQueue(upToId: number): Promise<void> {
    const db = await this.dbPromise;
    const tx = db.transaction("offlineQueue", "readwrite");
    const store = tx.objectStore("offlineQueue");
    const range = IDBKeyRange.upperBound(upToId);
    store.delete(range);
    await new Promise<void>((resolve, reject) => {
      tx.oncomplete = () => resolve();
      tx.onerror = () => reject(tx.error);
    });
  }

  async queueSize(): Promise<number> {
    const db = await this.dbPromise;
    const tx = db.transaction("offlineQueue", "readonly");
    return reqToPromise(tx.objectStore("offlineQueue").count());
  }

  /** Close the database connection. */
  async close(): Promise<void> {
    const db = await this.dbPromise;
    db.close();
  }
}
