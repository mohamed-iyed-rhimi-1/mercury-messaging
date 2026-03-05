import { BinaryTransport } from "./transport";
import { Channel } from "./channel";
import { SyncEngine } from "./sync";
import { LocalStore } from "./store";
import { hexToBytes } from "./codec";
import { MlsClient } from "./mls";
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
  private mlsClient: MlsClient;
  private syncEngine: SyncEngine | null = null;
  private store: LocalStore | null = null;

  constructor(config: MercuryConfig) {
    this.transport = new BinaryTransport(config.url, config.token);
    try {
      const payload = JSON.parse(atob(config.token.split(".")[1]));
      if (!payload.tid || !payload.uid) throw new Error("Token missing tid or uid");
      this.tenantId = hexToBytes(payload.tid);
      this.userId = hexToBytes(payload.uid);
    } catch (e) {
      throw new Error(`Invalid token — must be a JWT with tid and uid claims: ${(e as Error).message}`);
    }
    this.mlsClient = new MlsClient(this.userId, config.MlsManager);
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
    this.mlsClient.destroy();
    this._state = "disconnected";
  }

  channel(channelId: string): Channel {
    let ch = this.channels.get(channelId);
    if (!ch) {
      ch = new Channel(this.transport, channelId, this.tenantId, this.userId, this.mlsClient);
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
