import { BinaryTransport } from "./transport";
import { Channel } from "./channel";
import { SyncEngine } from "./sync";
import { LocalStore } from "./store";
import { hexToBytes } from "./codec";
import type { MercuryConfig, ConnectionState } from "./types";

/**
 * Mercury SDK client. Entry point for connecting to the gateway
 * and interacting with channels.
 *
 * @example
 * ```ts
 * const client = new MercuryClient({ url: "ws://gw.example.com", token: jwt });
 * await client.connect();
 * const ch = client.channel("general");
 * await ch.join();
 * await ch.send("hello");
 * ```
 */
export class MercuryClient {
  private transport: BinaryTransport;
  private channels = new Map<string, Channel>();
  private _state: ConnectionState = "disconnected";
  private tenantId: Uint8Array;
  private userId: Uint8Array;
  private syncEngine: SyncEngine | null = null;
  private store: LocalStore | null = null;

  constructor(config: MercuryConfig) {
    this.transport = new BinaryTransport(config.url, config.token);
    try {
      const payload = JSON.parse(atob(config.token.split(".")[1]));
      this.tenantId = hexToBytes(payload.tid ?? "");
      this.userId = hexToBytes(payload.uid ?? "");
    } catch {
      this.tenantId = new Uint8Array(16);
      this.userId = new Uint8Array(16);
    }
  }

  get state(): ConnectionState {
    return this._state;
  }

  enableOfflineSupport(): void {
    this.store = new LocalStore();
    this.syncEngine = new SyncEngine(this.store);
  }

  async connect(): Promise<void> {
    this._state = "connecting";

    this.transport.onReconnect(() => {
      this._state = "connected";
      if (this.syncEngine) {
        for (const [channelId, channel] of this.channels) {
          this.syncEngine.syncChannel(channel, channelId).catch(() => {});
        }
      }
    });

    await this.transport.connect();
    this._state = "connected";
  }

  disconnect(): void {
    this.transport.disconnect();
    this.channels.clear();
    this._state = "disconnected";
  }

  channel(channelId: string): Channel {
    let ch = this.channels.get(channelId);
    if (!ch) {
      ch = new Channel(this.transport, channelId, this.tenantId, this.userId);
      if (this.syncEngine) ch.syncEngine = this.syncEngine;
      this.channels.set(channelId, ch);
    }
    return ch;
  }

  getSyncEngine(): SyncEngine | null {
    return this.syncEngine;
  }

  getStore(): LocalStore | null {
    return this.store;
  }
}
