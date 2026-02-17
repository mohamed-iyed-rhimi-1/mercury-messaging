import type { BinaryTransport } from "./transport";
import type { SyncEngine } from "./sync";
import type { Message, HistoryOptions, MessageHandler, TypingHandler, ReadHandler } from "./types";
import {
  encodeEnvelope, decodeEnvelope,
  encodeTyping, decodeTyping,
  encodeReadReceipt, decodeReadReceipt,
  encodeMlsCommit, decodeMlsCommit,
  encodeMlsWelcome,
  hexToBytes, bytesToHex,
} from "./codec";
import {
  EV_MSG_SEND, EV_MSG_NEW, EV_MSG_HISTORY, EV_MSG_TYPING, EV_MSG_READ,
  EV_MLS_KEY_PACKAGE, EV_MLS_FETCH_KP, EV_MLS_COMMIT, EV_MLS_WELCOME, EV_MLS_REMOVE,
  EV_SYNC_REQUEST, EV_SYNC_PUSH, EV_SYNC_CURSOR, EV_CH_CREATE,
  packEnvelopes, unpackEnvelopes,
} from "./frame";
import type { MlsClient } from "./mls";

/**
 * A channel represents a conversation. Uses raw binary frames
 * with Cap'n Proto envelopes. No JSON, no base64 on the wire.
 */
export class Channel {
  private topic: string;
  private messageHandlers: MessageHandler[] = [];
  private typingHandlers: TypingHandler[] = [];
  private readHandlers: ReadHandler[] = [];
  public mls: MlsClient | null = null;
  public syncEngine: SyncEngine | null = null;
  private channelIdBytes: Uint8Array;

  constructor(
    private transport: BinaryTransport,
    private channelId: string,
    private tenantId: Uint8Array,
    private userId: Uint8Array,
  ) {
    this.topic = `channel:${channelId}`;
    this.channelIdBytes = new TextEncoder().encode(channelId);
  }

  async join(): Promise<void> {
    await this.transport.join(this.topic);

    this.transport.onByName(this.topic, EV_MSG_NEW, (data) => {
      const env = decodeEnvelope(data);
      let payload = env.payload;
      if (this.mls) {
        try { payload = this.mls.decrypt(this.channelIdBytes, payload); } catch { /* own msg */ }
      }
      const msg: Message = {
        id: bytesToHex(env.messageId),
        sender: bytesToHex(env.senderId),
        content: new TextDecoder().decode(payload),
        contentType: 0,
        timestamp: Number(env.timestamp),
      } as Message;
      for (const h of this.messageHandlers) h(msg);
    });

    this.transport.onByName(this.topic, EV_MSG_TYPING, (data) => {
      const ev = decodeTyping(data);
      for (const h of this.typingHandlers) h({ userId: bytesToHex(ev.userId) });
    });

    this.transport.onByName(this.topic, EV_MSG_READ, (data) => {
      const rr = decodeReadReceipt(data);
      for (const h of this.readHandlers) h({ userId: bytesToHex(rr.userId), messageId: bytesToHex(rr.messageId) });
    });

    this.transport.onByName(this.topic, EV_MLS_COMMIT, (data) => {
      if (!this.mls) return;
      try {
        const commit = decodeMlsCommit(data);
        this.mls.processCommit(this.channelIdBytes, commit);
      } catch { /* own commit */ }
    });
  }

  async send(content: string, contentType = 0): Promise<{ id: string }> {
    if (this.syncEngine && !this.transport.isConnected()) {
      const msgId = bytesToHex(crypto.getRandomValues(new Uint8Array(16)));
      await this.syncEngine.queueOffline(this.channelId, "msg:send", {
        content, content_type: contentType, message_id: msgId, hlc_wall: Date.now(),
      });
      return { id: msgId };
    }

    const ts = BigInt(Date.now());
    const msgId = crypto.getRandomValues(new Uint8Array(16));
    let payload = new TextEncoder().encode(content);
    if (this.mls) payload = new Uint8Array(this.mls.encrypt(this.channelIdBytes, payload));

    const channelIdBytes = hexToBytes(this.channelId.padStart(32, "0").slice(0, 32));
    const envelope = encodeEnvelope({ tenantId: this.tenantId, channelId: channelIdBytes, senderId: this.userId, messageId: msgId, timestamp: ts, payload });

    const reply = await this.transport.push(this.topic, EV_MSG_SEND, envelope);
    // Reply data is the message ID (16 bytes)
    return { id: bytesToHex(reply.length >= 16 ? reply.subarray(0, 16) : reply) };
  }

  async history(opts: HistoryOptions = {}): Promise<{ messages: Message[] }> {
    const limit = opts.limit ?? 50;
    const payload = new Uint8Array(4);
    new DataView(payload.buffer).setUint32(0, limit, true);

    const reply = await this.transport.push(this.topic, EV_MSG_HISTORY, payload);
    const envelopes = unpackEnvelopes(reply);

    const messages = envelopes.map((envBytes) => {
      const env = decodeEnvelope(envBytes);
      let data = env.payload;
      if (this.mls) {
        try { data = this.mls.decrypt(this.channelIdBytes, data); } catch { /* old msg */ }
      }
      return {
        id: bytesToHex(env.messageId),
        sender: bytesToHex(env.senderId),
        content: new TextDecoder().decode(data),
        contentType: 0,
        timestamp: Number(env.timestamp),
      } as Message;
    });
    return { messages };
  }

  sendTyping(): void {
    const bin = encodeTyping(this.userId);
    this.transport.push(this.topic, EV_MSG_TYPING, bin).catch(() => {});
  }

  async markRead(messageId: string): Promise<void> {
    const bin = encodeReadReceipt(this.userId, hexToBytes(messageId));
    await this.transport.push(this.topic, EV_MSG_READ, bin);
  }

  async sync(lastHlcWall = 0, limit = 100): Promise<{ deltas: unknown[]; serverHlc: number; hasMore: boolean }> {
    const payload = new Uint8Array(16);
    const view = new DataView(payload.buffer);
    // Pack as <<since_wall:64LE, limit:32LE, last_counter:32LE>>
    view.setBigUint64(0, BigInt(lastHlcWall), true);
    view.setUint32(8, limit, true);
    view.setUint32(12, 0, true);

    const reply = await this.transport.push(this.topic, EV_SYNC_REQUEST, payload);
    // Reply: <<server_hlc:64LE, has_more:8, packed_envelopes...>>
    const rv = new DataView(reply.buffer, reply.byteOffset, reply.byteLength);
    const serverHlc = Number(rv.getBigUint64(0, true));
    const hasMore = reply[8] === 1;
    const envelopes = unpackEnvelopes(reply.subarray(9));

    const deltas = envelopes.map((envBytes) => {
      const env = decodeEnvelope(envBytes);
      return {
        type: "MessageAppend",
        message_id: bytesToHex(env.messageId),
        sender_id: bytesToHex(env.senderId),
        encrypted_content: env.payload,
        content_type: 0,
        hlc_wall: Number(env.timestamp),
      };
    });
    return { deltas, serverHlc, hasMore };
  }

  async pushDeltas(deltas: unknown[]): Promise<{ accepted: number; serverHlc: number }> {
    const envelopes = deltas.map((d) => {
      const delta = d as Record<string, unknown>;
      return encodeEnvelope({
        tenantId: this.tenantId,
        channelId: this.userId,
        senderId: this.userId,
        messageId: hexToBytes((delta.message_id as string) ?? "00".repeat(16)),
        timestamp: BigInt((delta.hlc_wall as number) ?? Date.now()),
        payload: (delta.encrypted_content instanceof Uint8Array)
          ? delta.encrypted_content
          : new Uint8Array(0),
      });
    });
    const packed = packEnvelopes(envelopes);
    const reply = await this.transport.push(this.topic, EV_SYNC_PUSH, packed);
    // Reply: <<accepted:32LE, server_hlc:64LE>>
    const rv = new DataView(reply.buffer, reply.byteOffset, reply.byteLength);
    return { accepted: rv.getUint32(0, true), serverHlc: Number(rv.getBigUint64(4, true)) };
  }

  // ── MLS ──

  createMlsGroup(): void {
    if (!this.mls) throw new Error("MLS not configured");
    this.mls.createGroup(this.channelIdBytes);
  }

  async addMlsMember(userId: string, keyPackage: Uint8Array): Promise<void> {
    if (!this.mls) throw new Error("MLS not configured");
    const { commit, welcome } = this.mls.addMember(this.channelIdBytes, keyPackage);
    const commitCapnp = encodeMlsCommit(commit);
    await this.transport.push(this.topic, EV_MLS_COMMIT, commitCapnp);
    // Welcome: <<uid_len:16LE, uid, welcome_capnp>>
    const uidBytes = hexToBytes(userId);
    const welcomeCapnp = encodeMlsWelcome(welcome, uidBytes);
    const welcomePayload = new Uint8Array(2 + uidBytes.length + welcomeCapnp.length);
    new DataView(welcomePayload.buffer).setUint16(0, uidBytes.length, true);
    welcomePayload.set(uidBytes, 2);
    welcomePayload.set(welcomeCapnp, 2 + uidBytes.length);
    await this.transport.push(this.topic, EV_MLS_WELCOME, welcomePayload);
  }

  async removeMlsMember(userId: string): Promise<void> {
    const uidBytes = hexToBytes(userId);
    const commitCapnp = encodeMlsCommit(new Uint8Array(0));
    const payload = new Uint8Array(16 + commitCapnp.length);
    payload.set(uidBytes.subarray(0, 16), 0);
    payload.set(commitCapnp, 16);
    await this.transport.push(this.topic, EV_MLS_REMOVE, payload);
  }

  async fetchKeyPackages(userId: string): Promise<Uint8Array[]> {
    const uidBytes = hexToBytes(userId);
    const reply = await this.transport.push(this.topic, EV_MLS_FETCH_KP, uidBytes);
    const { decodeMlsKeyPackageList } = await import("./codec");
    return decodeMlsKeyPackageList(reply);
  }

  async uploadKeyPackage(keyPackage: Uint8Array): Promise<void> {
    const { encodeMlsKeyPackage } = await import("./codec");
    const capnp = encodeMlsKeyPackage(keyPackage);
    await this.transport.push(this.topic, EV_MLS_KEY_PACKAGE, capnp);
  }

  on(event: "message", handler: MessageHandler): void;
  on(event: "typing", handler: TypingHandler): void;
  on(event: "read", handler: ReadHandler): void;
  on(event: "message" | "typing" | "read", handler: MessageHandler | TypingHandler | ReadHandler): void {
    switch (event) {
      case "message": this.messageHandlers.push(handler as MessageHandler); break;
      case "typing": this.typingHandlers.push(handler as TypingHandler); break;
      case "read": this.readHandlers.push(handler as ReadHandler); break;
    }
  }
}
