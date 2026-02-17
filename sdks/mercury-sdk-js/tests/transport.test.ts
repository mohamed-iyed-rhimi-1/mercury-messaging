import { describe, test, expect, mock } from "bun:test";
import { BinaryTransport } from "../src/transport";

describe("BinaryTransport", () => {
  test("constructs without connecting", () => {
    const transport = new BinaryTransport("ws://localhost:4000", "test-token");
    expect(transport).toBeDefined();
  });

  test("disconnect is safe to call when not connected", () => {
    const transport = new BinaryTransport("ws://localhost:4000", "test-token");
    transport.disconnect();
  });

  test("isConnected returns false when not connected", () => {
    const transport = new BinaryTransport("ws://localhost:4000", "test-token");
    expect(transport.isConnected()).toBe(false);
  });
});
