import { describe, test, expect } from "bun:test";
import {
  encodeFrame, decodeFrame,
  packEnvelopes, unpackEnvelopes,
  FRAME_PUSH, FRAME_HEARTBEAT,
} from "../src/frame";

describe("frame codec", () => {
  test("encode/decode roundtrip", () => {
    const payload = new Uint8Array([1, 2, 3, 4]);
    const frame = encodeFrame(FRAME_PUSH, 42, 7, payload);
    const decoded = decodeFrame(frame);
    expect(decoded.type).toBe(FRAME_PUSH);
    expect(decoded.ref).toBe(42);
    expect(decoded.topicId).toBe(7);
    expect(Array.from(decoded.payload)).toEqual([1, 2, 3, 4]);
  });

  test("heartbeat frame has no payload", () => {
    const frame = encodeFrame(FRAME_HEARTBEAT, 1, 0);
    expect(frame.length).toBe(7); // header only
    const decoded = decodeFrame(frame);
    expect(decoded.type).toBe(FRAME_HEARTBEAT);
    expect(decoded.payload.length).toBe(0);
  });

  test("pack/unpack envelopes roundtrip", () => {
    const envs = [
      new Uint8Array([10, 20, 30]),
      new Uint8Array([40, 50]),
      new Uint8Array([60]),
    ];
    const packed = packEnvelopes(envs);
    const unpacked = unpackEnvelopes(packed);
    expect(unpacked.length).toBe(3);
    expect(Array.from(unpacked[0])).toEqual([10, 20, 30]);
    expect(Array.from(unpacked[1])).toEqual([40, 50]);
    expect(Array.from(unpacked[2])).toEqual([60]);
  });

  test("unpack empty returns empty", () => {
    const packed = packEnvelopes([]);
    const unpacked = unpackEnvelopes(packed);
    expect(unpacked.length).toBe(0);
  });
});
