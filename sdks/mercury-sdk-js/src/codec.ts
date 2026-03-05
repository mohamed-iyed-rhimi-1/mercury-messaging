/**
 * Cap'n Proto envelope codec for the Mercury wire format.
 * Encodes/decodes Envelope structs for transport over Phoenix channels.
 */
import * as capnp from "capnp-es";
import { Envelope } from "./proto/mercury/v1/envelope.js";
import {
  TypingEvent,
  ReadReceipt,
  MlsKeyPackage,
  MlsKeyPackageList,
  MlsCommit,
  MlsWelcome,
} from "./proto/mercury/v1/event.js";

export interface EnvelopeFields {
  tenantId: Uint8Array;
  channelId: Uint8Array;
  senderId: Uint8Array;
  messageId: Uint8Array;
  timestamp: bigint;
  payload: Uint8Array;
}

function copyInto(data: capnp.Data, src: Uint8Array): void {
  for (let i = 0; i < src.length; i++) data.set(i, src[i]);
}

/** Serialize envelope fields to Cap'n Proto bytes. */
export function encodeEnvelope(fields: EnvelopeFields): Uint8Array {
  const msg = new capnp.Message();
  const env = msg.initRoot(Envelope);

  copyInto(env._initTenantId(fields.tenantId.length), fields.tenantId);
  copyInto(env._initChannelId(fields.channelId.length), fields.channelId);
  copyInto(env._initSenderId(fields.senderId.length), fields.senderId);
  copyInto(env._initMessageId(fields.messageId.length), fields.messageId);
  env.timestamp = fields.timestamp;
  copyInto(env._initPayload(fields.payload.length), fields.payload);

  return new Uint8Array(msg.toArrayBuffer());
}

/** Deserialize Cap'n Proto bytes into envelope fields. */
export function decodeEnvelope(bytes: Uint8Array): EnvelopeFields {
  const buf = bytes.buffer.slice(bytes.byteOffset, bytes.byteOffset + bytes.byteLength);
  const msg = new capnp.Message(buf as ArrayBuffer, false);
  const env = msg.getRoot(Envelope);

  return {
    tenantId: new Uint8Array(env.tenantId.toArray()),
    channelId: new Uint8Array(env.channelId.toArray()),
    senderId: new Uint8Array(env.senderId.toArray()),
    messageId: new Uint8Array(env.messageId.toArray()),
    timestamp: env.timestamp,
    payload: new Uint8Array(env.payload.toArray()),
  };
}

/** Hex string to Uint8Array. */
export function hexToBytes(hex: string): Uint8Array {
  const bytes = new Uint8Array(hex.length / 2);
  for (let i = 0; i < hex.length; i += 2) {
    bytes[i / 2] = parseInt(hex.substring(i, i + 2), 16);
  }
  return bytes;
}

/** Uint8Array to hex string (lowercase). */
export function bytesToHex(bytes: Uint8Array): string {
  return Array.from(bytes)
    .map((b) => b.toString(16).padStart(2, "0"))
    .join("");
}

// ── Event codecs ──

export function encodeTyping(userId: Uint8Array): Uint8Array {
  const msg = new capnp.Message();
  const ev = msg.initRoot(TypingEvent);
  copyInto(ev._initUserId(userId.length), userId);
  return new Uint8Array(msg.toArrayBuffer());
}

export function decodeTyping(bytes: Uint8Array): { userId: Uint8Array } {
  const buf = bytes.buffer.slice(bytes.byteOffset, bytes.byteOffset + bytes.byteLength);
  const msg = new capnp.Message(buf as ArrayBuffer, false);
  const ev = msg.getRoot(TypingEvent);
  return { userId: new Uint8Array(ev.userId.toArray()) };
}

export function encodeReadReceipt(userId: Uint8Array, messageId: Uint8Array): Uint8Array {
  const msg = new capnp.Message();
  const rr = msg.initRoot(ReadReceipt);
  copyInto(rr._initUserId(userId.length), userId);
  copyInto(rr._initMessageId(messageId.length), messageId);
  return new Uint8Array(msg.toArrayBuffer());
}

export function decodeReadReceipt(bytes: Uint8Array): { userId: Uint8Array; messageId: Uint8Array } {
  const buf = bytes.buffer.slice(bytes.byteOffset, bytes.byteOffset + bytes.byteLength);
  const msg = new capnp.Message(buf as ArrayBuffer, false);
  const rr = msg.getRoot(ReadReceipt);
  return {
    userId: new Uint8Array(rr.userId.toArray()),
    messageId: new Uint8Array(rr.messageId.toArray()),
  };
}

export function encodeMlsKeyPackage(keyPackage: Uint8Array): Uint8Array {
  const msg = new capnp.Message();
  const kp = msg.initRoot(MlsKeyPackage);
  copyInto(kp._initKeyPackage(keyPackage.length), keyPackage);
  return new Uint8Array(msg.toArrayBuffer());
}

export function decodeMlsKeyPackage(bytes: Uint8Array): Uint8Array {
  const buf = bytes.buffer.slice(bytes.byteOffset, bytes.byteOffset + bytes.byteLength);
  const msg = new capnp.Message(buf as ArrayBuffer, false);
  return new Uint8Array(msg.getRoot(MlsKeyPackage).keyPackage.toArray());
}

export function encodeMlsKeyPackageList(packages: Uint8Array[]): Uint8Array {
  const msg = new capnp.Message();
  const list = msg.initRoot(MlsKeyPackageList);
  const kps = list._initKeyPackages(packages.length);
  for (let i = 0; i < packages.length; i++) {
    // For List<Data>, set each element as a Data (List<number>)
    // We need to init each slot then copy bytes in
    const slot = capnp.utils.initData(i, packages[i].length, kps as unknown as capnp.Pointer);
    copyInto(slot, packages[i]);
  }
  return new Uint8Array(msg.toArrayBuffer());
}

export function decodeMlsKeyPackageList(bytes: Uint8Array): Uint8Array[] {
  const buf = bytes.buffer.slice(bytes.byteOffset, bytes.byteOffset + bytes.byteLength);
  const msg = new capnp.Message(buf as ArrayBuffer, false);
  const list = msg.getRoot(MlsKeyPackageList).keyPackages;
  const out: Uint8Array[] = [];
  for (let i = 0; i < list.length; i++) {
    out.push(new Uint8Array(list.get(i).toArray()));
  }
  return out;
}

export function encodeMlsCommit(commit: Uint8Array): Uint8Array {
  const msg = new capnp.Message();
  const c = msg.initRoot(MlsCommit);
  copyInto(c._initCommit(commit.length), commit);
  return new Uint8Array(msg.toArrayBuffer());
}

export function decodeMlsCommit(bytes: Uint8Array): Uint8Array {
  const buf = bytes.buffer.slice(bytes.byteOffset, bytes.byteOffset + bytes.byteLength);
  const msg = new capnp.Message(buf as ArrayBuffer, false);
  return new Uint8Array(msg.getRoot(MlsCommit).commit.toArray());
}

export function encodeMlsWelcome(welcome: Uint8Array, userId: Uint8Array): Uint8Array {
  const msg = new capnp.Message();
  const w = msg.initRoot(MlsWelcome);
  copyInto(w._initWelcome(welcome.length), welcome);
  copyInto(w._initUserId(userId.length), userId);
  return new Uint8Array(msg.toArrayBuffer());
}

export function decodeMlsWelcome(bytes: Uint8Array): { welcome: Uint8Array; userId: Uint8Array } {
  const buf = bytes.buffer.slice(bytes.byteOffset, bytes.byteOffset + bytes.byteLength);
  const msg = new capnp.Message(buf as ArrayBuffer, false);
  const w = msg.getRoot(MlsWelcome);
  return {
    welcome: new Uint8Array(w.welcome.toArray()),
    userId: new Uint8Array(w.userId.toArray()),
  };
}
