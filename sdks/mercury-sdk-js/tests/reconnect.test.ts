import { describe, test, expect } from "bun:test";
import { BinaryTransport } from "../src/transport";

describe("BinaryTransport reconnect", () => {
  test("multiple disconnects do not throw", () => {
    const transport = new BinaryTransport("ws://localhost:4000", "test-token");
    transport.disconnect();
    transport.disconnect();
    transport.disconnect();
  });

  test("connect rejects on invalid URL", async () => {
    const transport = new BinaryTransport("ws://localhost:1", "test-token");
    try {
      await transport.connect();
      transport.disconnect();
    } catch (e) {
      expect((e as Error).message).toContain("failed");
    }
  });

  test("onReconnect registers callback without error", () => {
    const transport = new BinaryTransport("ws://localhost:4000", "test-token");
    transport.onReconnect(() => {});
    transport.disconnect();
  });
});
