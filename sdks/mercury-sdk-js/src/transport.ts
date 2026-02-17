/**
 * Binary WebSocket transport for Mercury.
 * Sends/receives raw binary frames — no JSON, no base64.
 */

import {
  encodeFrame,
  decodeFrame,
  FRAME_JOIN,
  FRAME_LEAVE,
  FRAME_REPLY,
  FRAME_PUSH,
  FRAME_BROADCAST,
  FRAME_HEARTBEAT,
  STATUS_OK,
} from "./frame";

const HEARTBEAT_INTERVAL = 30_000;
const RECONNECT_DELAYS = [1000, 2000, 4000, 8000, 16000, 30_000];

type ReplyCallback = (status: number, data: Uint8Array) => void;
type EventCallback = (payload: Uint8Array) => void;
type ReconnectCallback = () => void;

export class BinaryTransport {
  private ws: WebSocket | null = null;
  private ref = 0;
  private heartbeatTimer: ReturnType<typeof setInterval> | null = null;
  private pendingReplies = new Map<number, ReplyCallback>();
  private topicBindings = new Map<number, Map<number, EventCallback>>();
  private topicNameToId = new Map<string, number>();
  private topicIdToName = new Map<number, string>();
  private joinedTopics = new Set<string>();
  private reconnectAttempt = 0;
  private closed = false;
  private reconnectCallbacks: ReconnectCallback[] = [];

  constructor(
    private url: string,
    private token: string,
  ) {}

  connect(): Promise<void> {
    this.closed = false;
    return new Promise((resolve, reject) => {
      const base = this.url.replace(/\/+$/, "");
      const wsUrl = `${base}/ws?token=${encodeURIComponent(this.token)}`;
      this.ws = new WebSocket(wsUrl);
      this.ws.binaryType = "arraybuffer";

      this.ws.onopen = () => {
        this.reconnectAttempt = 0;
        this.startHeartbeat();
        resolve();
      };

      this.ws.onmessage = (event) => {
        this.handleMessage(new Uint8Array(event.data as ArrayBuffer));
      };

      this.ws.onclose = () => {
        this.stopHeartbeat();
        if (!this.closed) this.scheduleReconnect();
      };

      this.ws.onerror = () => {
        reject(new Error("WebSocket connection failed"));
      };
    });
  }

  disconnect(): void {
    this.closed = true;
    this.stopHeartbeat();
    this.ws?.close();
    this.ws = null;
    this.joinedTopics.clear();
    this.topicNameToId.clear();
    this.topicIdToName.clear();
  }

  join(topic: string): Promise<void> {
    return new Promise((resolve, reject) => {
      const ref = this.nextRef();
      const topicBytes = new TextEncoder().encode(topic);
      this.pendingReplies.set(ref, (status, data) => {
        if (status === STATUS_OK) {
          // Server assigned topic ID is in the frame header
          // We extract it from the reply frame's topicId field
          this.joinedTopics.add(topic);
          resolve();
        } else {
          reject(new Error(`Join failed: ${new TextDecoder().decode(data)}`));
        }
      });
      // Join sends topic_id=0 (not yet assigned), topic name in payload
      this.send(encodeFrame(FRAME_JOIN, ref, 0, topicBytes));
    });
  }

  push(topic: string, event: number, payload: Uint8Array): Promise<Uint8Array> {
    return new Promise((resolve, reject) => {
      const topicId = this.topicNameToId.get(topic);
      if (topicId === undefined) {
        reject(new Error(`Not joined: ${topic}`));
        return;
      }
      const ref = this.nextRef();
      this.pendingReplies.set(ref, (status, data) => {
        if (status === STATUS_OK) resolve(data);
        else reject(new Error(`Push failed: ${new TextDecoder().decode(data)}`));
      });
      const frame = encodeFrame(FRAME_PUSH, ref, topicId, concat(new Uint8Array([event]), payload));
      this.send(frame);
    });
  }

  on(topicId: number, event: number, callback: EventCallback): void {
    if (!this.topicBindings.has(topicId)) {
      this.topicBindings.set(topicId, new Map());
    }
    this.topicBindings.get(topicId)!.set(event, callback);
  }

  onByName(topic: string, event: number, callback: EventCallback): void {
    // Deferred binding — will be resolved when topic ID is known
    const existing = this.topicNameToId.get(topic);
    if (existing !== undefined) {
      this.on(existing, event, callback);
    }
    // Store for later resolution
    const key = `${topic}:${event}`;
    (this as unknown as Record<string, EventCallback[]>)[`_deferred_${key}`] ??= [];
    (this as unknown as Record<string, EventCallback[]>)[`_deferred_${key}`].push(callback);
  }

  off(topicId: number, event: number): void {
    this.topicBindings.get(topicId)?.delete(event);
  }

  onReconnect(callback: ReconnectCallback): void {
    this.reconnectCallbacks.push(callback);
  }

  isConnected(): boolean {
    return this.ws?.readyState === WebSocket.OPEN;
  }

  getTopicId(topic: string): number | undefined {
    return this.topicNameToId.get(topic);
  }

  private handleMessage(data: Uint8Array): void {
    const frame = decodeFrame(data);

    if (frame.type === FRAME_REPLY) {
      const status = frame.payload.length > 0 ? frame.payload[0] : STATUS_OK;
      const replyData = frame.payload.subarray(1);

      // On join reply, register the topic ID mapping
      const cb = this.pendingReplies.get(frame.ref);
      if (cb) {
        // If this is a join reply (topicId > 0 and status OK), register mapping
        if (frame.topicId > 0 && status === STATUS_OK) {
          // Find which topic this join was for
          for (const topic of this.joinedTopics) {
            if (!this.topicNameToId.has(topic)) {
              this.topicNameToId.set(topic, frame.topicId);
              this.topicIdToName.set(frame.topicId, topic);
              this.resolveDeferredBindings(topic, frame.topicId);
              break;
            }
          }
        }
        this.pendingReplies.delete(frame.ref);
        cb(status, replyData);
      }
      return;
    }

    if (frame.type === FRAME_BROADCAST) {
      const event = frame.payload[0];
      const eventData = frame.payload.subarray(1);
      const bindings = this.topicBindings.get(frame.topicId);
      bindings?.get(event)?.(eventData);
    }
  }

  private resolveDeferredBindings(topic: string, topicId: number): void {
    // Move any deferred bindings to the real topic ID
    const self = this as unknown as Record<string, EventCallback[]>;
    for (const key of Object.keys(self)) {
      if (key.startsWith(`_deferred_${topic}:`)) {
        const event = parseInt(key.split(":").pop()!, 10);
        const callbacks = self[key];
        for (const cb of callbacks) {
          this.on(topicId, event, cb);
        }
        delete self[key];
      }
    }
  }

  private send(data: Uint8Array): void {
    if (this.ws?.readyState === WebSocket.OPEN) {
      this.ws.send(data);
    }
  }

  private nextRef(): number {
    this.ref += 1;
    return this.ref;
  }

  private startHeartbeat(): void {
    this.heartbeatTimer = setInterval(() => {
      this.send(encodeFrame(FRAME_HEARTBEAT, this.nextRef(), 0));
    }, HEARTBEAT_INTERVAL);
  }

  private stopHeartbeat(): void {
    if (this.heartbeatTimer) {
      clearInterval(this.heartbeatTimer);
      this.heartbeatTimer = null;
    }
  }

  private scheduleReconnect(): void {
    const delay = RECONNECT_DELAYS[Math.min(this.reconnectAttempt, RECONNECT_DELAYS.length - 1)];
    this.reconnectAttempt += 1;
    setTimeout(() => {
      if (!this.closed) {
        this.connect()
          .then(() => {
            const rejoinPromises = [...this.joinedTopics].map((topic) => {
              // Clear old mapping so join assigns new ID
              const oldId = this.topicNameToId.get(topic);
              if (oldId !== undefined) {
                this.topicNameToId.delete(topic);
                this.topicIdToName.delete(oldId);
              }
              return this.join(topic).catch(() => {});
            });
            Promise.all(rejoinPromises).then(() => {
              for (const cb of this.reconnectCallbacks) {
                try { cb(); } catch { /* ignore */ }
              }
            });
          })
          .catch(() => this.scheduleReconnect());
      }
    }, delay);
  }
}

function concat(a: Uint8Array, b: Uint8Array): Uint8Array {
  const out = new Uint8Array(a.length + b.length);
  out.set(a, 0);
  out.set(b, a.length);
  return out;
}
