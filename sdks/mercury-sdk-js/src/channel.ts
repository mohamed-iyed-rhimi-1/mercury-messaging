import type { BinaryTransport } from "./transport";
import type { SyncEngine } from "./sync";
import type { Message, HistoryOptions, MessageHandler, TypingHandler, ReadHandler } from "./types";
import {
  encodeEnvelope, decodeEnvelope,
  encodeTyping, decodeTyping,
  encodeReadReceipt, decodeReadReceipt,
  encodeMlsCommit, decodeMlsCommit,
  encodeMlsWelcome, decodeMlsWelcome,
  hexToBytes, bytesToHex,
} from "./codec";
import {
  EV_MSG_SEND, EV_MSG_NEW, EV_MSG_HISTORY, EV_MSG_TYPING, EV_MSG_READ,
  EV_MLS_KEY_PACKAGE, EV_MLS_FETCH_KP, EV_MLS_COMMIT, EV_MLS_WELCOME,
  EV_MLS_MEMBERS, EV_MLS_GROUP_INFO, EV_MLS_CEK, EV_PRESENCE_JOIN,
  EV_SYNC_REQUEST, EV_SYNC_PUSH,
  packEnvelopes, unpackEnvelopes,
} from "./frame";
import type { MlsClient } from "./mls";

/**
 * A channel represents a conversation. All messages are E2EE via MLS.
 * Call join() and await it before sending — it blocks until the MLS
 * handshake completes.
 */
export class Channel {
  private topic: string;
  private messageHandlers: MessageHandler[] = [];
  private typingHandlers: TypingHandler[] = [];
  private readHandlers: ReadHandler[] = [];
  public syncEngine: SyncEngine | null = null;
  private channelIdBytes: Uint8Array;
  private mlsReady = false;
  private mlsReadyCallbacks: (() => void)[] = [];
  private isGroupCreator = false;

  constructor(
    private transport: BinaryTransport,
    private channelId: string,
    private tenantId: Uint8Array,
    private userId: Uint8Array,
    private mls: MlsClient,
  ) {
    this.topic = `channel:${channelId}`;
    this.channelIdBytes = hexToBytes(channelId);
  }

  async join(): Promise<void> {
    await this.transport.join(this.topic);

    // ── Register event handlers ──

    this.transport.onByName(this.topic, EV_MSG_NEW, (data) => {
      const env = decodeEnvelope(data);
      const senderId = bytesToHex(env.senderId);
      const myId = bytesToHex(this.userId);
      if (senderId === myId) return;
      this.mls.decrypt(this.channelIdBytes, env.payload)
        .then((pt) => {
          const msg: Message = {
            id: bytesToHex(env.messageId),
            sender: bytesToHex(env.senderId),
            content: new TextDecoder().decode(pt),
            contentType: 0,
            timestamp: Number(env.timestamp),
          } as Message;
          for (const h of this.messageHandlers) h(msg);
        })
        .catch(() => { /* undecryptable */ });
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
      try {
        const commit = decodeMlsCommit(data);
        this.mls.processCommit(this.channelIdBytes, commit);
      } catch { /* own commit or not in group yet */ }
    });

    this.transport.onByName(this.topic, EV_MLS_WELCOME, (data) => {
      if (this.mlsReady) return;
      try {
        const view = new DataView(data.buffer, data.byteOffset, data.byteLength);
        const uidLen = view.getUint16(0, true);
        const targetUid = data.subarray(2, 2 + uidLen);
        if (bytesToHex(targetUid) !== bytesToHex(this.userId)) return;
        const welcomeCapnp = data.subarray(2 + uidLen);
        const { welcome } = decodeMlsWelcome(welcomeCapnp);
        this.mls.processWelcome(welcome);
      } catch (e) { console.error("[MLS] Welcome error:", e); }
    });

    this.transport.onByName(this.topic, EV_MLS_CEK, (data) => {
      if (this.mlsReady) return;
      this.mls.tryDecryptCek(this.channelIdBytes, data)
        .then((wasCek) => { if (wasCek) this.setMlsReady(); })
        .catch((e) => { console.error("[MLS] CEK decrypt error:", e); });
    });

    this.transport.onByName(this.topic, EV_PRESENCE_JOIN, (data) => {
      if (!this.mlsReady || !this.isGroupCreator) return;
      if (data.length < 16) return;
      const joinerUid = data.subarray(0, 16);
      if (bytesToHex(joinerUid) === bytesToHex(this.userId)) return;
      this.addNewMember(joinerUid).catch((e) => console.error("[MLS] addNewMember error:", e));
    });

    this.transport.onByName(this.topic, EV_MLS_KEY_PACKAGE, (data) => {
      if (!this.mlsReady || !this.isGroupCreator) return;
      if (data.length < 16) return;
      const uploaderUid = data.subarray(0, 16);
      if (bytesToHex(uploaderUid) === bytesToHex(this.userId)) return;
      this.addNewMember(uploaderUid).catch(() => {});
    });

    // ── MLS handshake ──

    const kp = this.mls.generateKeyPackage();
    await this.uploadKeyPackage(kp);

    const groupInfo = await this.transport.push(this.topic, EV_MLS_GROUP_INFO, new Uint8Array(0));

    if (groupInfo[0] === 1) {
      await this.mls.createGroup(this.channelIdBytes);
      this.isGroupCreator = true;
      this.setMlsReady();
    } else {
      await new Promise<void>((resolve) => {
        const timeout = setTimeout(() => {
          if (!this.mlsReady) {
            this.transport.push(this.topic, EV_MLS_GROUP_INFO, new Uint8Array(0))
              .then(async () => {
                if (!this.mlsReady) {
                  try {
                    await this.mls.createGroup(this.channelIdBytes);
                    this.isGroupCreator = true;
                    this.setMlsReady();
                  } catch { /* already created */ }
                }
                resolve();
              })
              .catch(() => resolve());
          } else {
            resolve();
          }
        }, 5000);

        this.mlsReadyCallbacks.push(() => {
          clearTimeout(timeout);
          resolve();
        });
      });
    }
  }

  private setMlsReady(): void {
    this.mlsReady = true;
    for (const cb of this.mlsReadyCallbacks) cb();
    this.mlsReadyCallbacks = [];
  }

  private async addNewMember(joinerUid: Uint8Array): Promise<void> {
    try {
      const packages = await this.fetchKeyPackages(bytesToHex(joinerUid));
      if (packages.length === 0) return;
      await this.addMember(bytesToHex(joinerUid), packages[0]);
      const encryptedCek = this.mls.encryptCekForMember(this.channelIdBytes);
      await this.transport.push(this.topic, EV_MLS_CEK, encryptedCek);
    } catch (e) { console.error("[MLS] addNewMember failed:", e); }
  }

  isReady(): boolean {
    return this.mlsReady;
  }

  async send(content: string, contentType = 0): Promise<{ id: string }> {
    if (!this.mlsReady) throw new Error("Channel not ready — await join() first");

    if (this.syncEngine && !this.transport.isConnected()) {
      const msgId = bytesToHex(crypto.getRandomValues(new Uint8Array(16)));
      await this.syncEngine.queueOffline(this.channelId, "msg:send", {
        content, content_type: contentType, message_id: msgId, hlc_wall: Date.now(),
      });
      return { id: msgId };
    }

    const ts = BigInt(Date.now());
    const msgId = crypto.getRandomValues(new Uint8Array(16));
    const payload = new Uint8Array(await this.mls.encrypt(this.channelIdBytes, new TextEncoder().encode(content)));

    const envelope = encodeEnvelope({ tenantId: this.tenantId, channelId: this.channelIdBytes, senderId: this.userId, messageId: msgId, timestamp: ts, payload });

    const reply = await this.transport.push(this.topic, EV_MSG_SEND, envelope);

    const msg: Message = {
      id: bytesToHex(msgId),
      sender: bytesToHex(this.userId),
      content,
      contentType,
      timestamp: Number(ts),
    } as Message;
    for (const h of this.messageHandlers) h(msg);

    return { id: reply.length >= 16 ? bytesToHex(reply.subarray(0, 16)) : bytesToHex(msgId) };
  }

  async history(opts: HistoryOptions = {}): Promise<{ messages: Message[] }> {
    if (!this.mlsReady) throw new Error("Channel not ready — await join() first");

    const limit = opts.limit ?? 50;
    const payload = new Uint8Array(4);
    new DataView(payload.buffer).setUint32(0, limit, true);

    const reply = await this.transport.push(this.topic, EV_MSG_HISTORY, payload);
    const envelopes = unpackEnvelopes(reply);

    const messages = (await Promise.all(envelopes.map(async (envBytes) => {
      const env = decodeEnvelope(envBytes);
      let data = env.payload;
      try { data = await this.mls.decrypt(this.channelIdBytes, data); } catch { return null; }
      return {
        id: bytesToHex(env.messageId),
        sender: bytesToHex(env.senderId),
        content: new TextDecoder().decode(data),
        contentType: 0,
        timestamp: Number(env.timestamp),
      } as Message;
    }))).filter((m): m is Message => m !== null);
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
    view.setBigUint64(0, BigInt(lastHlcWall), true);
    view.setUint32(8, limit, true);
    view.setUint32(12, 0, true);

    const reply = await this.transport.push(this.topic, EV_SYNC_REQUEST, payload);
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
        channelId: this.channelIdBytes,
        senderId: this.userId,
        messageId: hexToBytes(delta.message_id as string),
        timestamp: BigInt((delta.hlc_wall as number) ?? Date.now()),
        payload: (delta.encrypted_content instanceof Uint8Array)
          ? delta.encrypted_content
          : new Uint8Array(0),
      });
    });
    const packed = packEnvelopes(envelopes);
    const reply = await this.transport.push(this.topic, EV_SYNC_PUSH, packed);
    const rv = new DataView(reply.buffer, reply.byteOffset, reply.byteLength);
    return { accepted: rv.getUint32(0, true), serverHlc: Number(rv.getBigUint64(4, true)) };
  }

  // ── MLS group management ──

  async addMember(userId: string, keyPackage: Uint8Array): Promise<void> {
    const { commit, welcome } = this.mls.addMember(this.channelIdBytes, keyPackage);
    const commitCapnp = encodeMlsCommit(commit);
    await this.transport.push(this.topic, EV_MLS_COMMIT, commitCapnp);
    const uidBytes = hexToBytes(userId);
    const welcomeCapnp = encodeMlsWelcome(welcome, uidBytes);
    const welcomePayload = new Uint8Array(2 + uidBytes.length + welcomeCapnp.length);
    new DataView(welcomePayload.buffer).setUint16(0, uidBytes.length, true);
    welcomePayload.set(uidBytes, 2);
    welcomePayload.set(welcomeCapnp, 2 + uidBytes.length);
    await this.transport.push(this.topic, EV_MLS_WELCOME, welcomePayload);
  }

  async removeMember(memberIndex: number): Promise<void> {
    const commit = this.mls.removeMember(this.channelIdBytes, memberIndex);
    await this.transport.push(this.topic, EV_MLS_COMMIT, encodeMlsCommit(commit));
  }

  memberCount(): number {
    return this.mls.memberCount(this.channelIdBytes);
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

  async fetchMembers(): Promise<Uint8Array[]> {
    const reply = await this.transport.push(this.topic, EV_MLS_MEMBERS, new Uint8Array(0));
    if (reply.length < 2) return [];
    const view = new DataView(reply.buffer, reply.byteOffset, reply.byteLength);
    const count = view.getUint16(0, true);
    const members: Uint8Array[] = [];
    for (let i = 0; i < count && 2 + (i + 1) * 16 <= reply.length; i++) {
      members.push(reply.slice(2 + i * 16, 2 + (i + 1) * 16));
    }
    return members;
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
