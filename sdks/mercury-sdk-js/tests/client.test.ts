import { describe, test, expect } from "bun:test";
import { MercuryClient } from "../src/client";

describe("MercuryClient", () => {
  test("starts disconnected", () => {
    const client = new MercuryClient({
      url: "ws://localhost:4000",
      token: "test-token",
    });
    expect(client.state).toBe("disconnected");
  });

  test("returns same channel instance for same id", () => {
    const client = new MercuryClient({
      url: "ws://localhost:4000",
      token: "test-token",
    });
    const ch1 = client.channel("general");
    const ch2 = client.channel("general");
    expect(ch1).toBe(ch2);
  });

  test("returns different channel instances for different ids", () => {
    const client = new MercuryClient({
      url: "ws://localhost:4000",
      token: "test-token",
    });
    const ch1 = client.channel("general");
    const ch2 = client.channel("random");
    expect(ch1).not.toBe(ch2);
  });

  test("disconnect clears channels", () => {
    const client = new MercuryClient({
      url: "ws://localhost:4000",
      token: "test-token",
    });
    client.channel("general");
    client.disconnect();
    expect(client.state).toBe("disconnected");
    const ch = client.channel("general");
    expect(ch).toBeDefined();
  });
});
