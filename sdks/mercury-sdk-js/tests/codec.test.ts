import { describe, test, expect } from "bun:test";
import {
  encodeEnvelope, decodeEnvelope,
  hexToBytes, bytesToHex,
  encodeTyping, decodeTyping,
  encodeReadReceipt, decodeReadReceipt,
  encodeMlsCommit, decodeMlsCommit,
  encodeMlsWelcome, decodeMlsWelcome,
  encodeMlsKeyPackage, decodeMlsKeyPackage,
} from "../src/codec";

describe("Cap'n Proto Codec", () => {
  test("roundtrip envelope encode/decode", () => {
    const fields = {
      tenantId: new Uint8Array([1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16]),
      channelId: new Uint8Array(16).fill(0xaa),
      senderId: new Uint8Array(16).fill(0xbb),
      messageId: new Uint8Array(16).fill(0xcc),
      timestamp: BigInt(1700000000000),
      payload: new TextEncoder().encode("hello capnp"),
    };

    const encoded = encodeEnvelope(fields);
    expect(encoded.length).toBeGreaterThan(0);
    expect(encoded.length).toBeLessThan(200);

    const decoded = decodeEnvelope(encoded);
    expect(decoded.tenantId).toEqual(fields.tenantId);
    expect(decoded.channelId).toEqual(fields.channelId);
    expect(decoded.senderId).toEqual(fields.senderId);
    expect(decoded.messageId).toEqual(fields.messageId);
    expect(decoded.timestamp).toBe(fields.timestamp);
    expect(decoded.payload).toEqual(new Uint8Array(fields.payload));
  });

  test("hex roundtrip", () => {
    const hex = "00FF80AABB";
    const bytes = hexToBytes(hex);
    expect(bytes).toEqual(new Uint8Array([0, 255, 128, 170, 187]));
    expect(bytesToHex(bytes)).toBe(hex);
  });
});

describe("Event Codecs", () => {
  test("typing roundtrip", () => {
    const userId = crypto.getRandomValues(new Uint8Array(16));
    const encoded = encodeTyping(userId);
    const decoded = decodeTyping(encoded);
    expect(decoded.userId).toEqual(userId);
  });

  test("read receipt roundtrip", () => {
    const userId = crypto.getRandomValues(new Uint8Array(16));
    const messageId = crypto.getRandomValues(new Uint8Array(16));
    const encoded = encodeReadReceipt(userId, messageId);
    const decoded = decodeReadReceipt(encoded);
    expect(decoded.userId).toEqual(userId);
    expect(decoded.messageId).toEqual(messageId);
  });

  test("MLS key package roundtrip", () => {
    const kp = crypto.getRandomValues(new Uint8Array(256));
    const encoded = encodeMlsKeyPackage(kp);
    const decoded = decodeMlsKeyPackage(encoded);
    expect(decoded).toEqual(kp);
  });

  test("MLS commit roundtrip", () => {
    const commit = crypto.getRandomValues(new Uint8Array(128));
    const encoded = encodeMlsCommit(commit);
    const decoded = decodeMlsCommit(encoded);
    expect(decoded).toEqual(commit);
  });

  test("MLS welcome roundtrip", () => {
    const welcome = crypto.getRandomValues(new Uint8Array(512));
    const userId = crypto.getRandomValues(new Uint8Array(16));
    const encoded = encodeMlsWelcome(welcome, userId);
    const decoded = decodeMlsWelcome(encoded);
    expect(decoded.welcome).toEqual(welcome);
    expect(decoded.userId).toEqual(userId);
  });
});
