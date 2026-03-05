import { describe, test, expect } from "bun:test";
import { MercuryClient } from "../src/client";
import type { WasmMlsManager } from "../src/mls";

/** Mock WASM MLS manager class for tests. */
class MockMlsManager implements WasmMlsManager {
  generateKeyPackage() { return new Uint8Array([1, 2, 3]); }
  createGroup() {}
  addMember() { return new Uint8Array([0, 0, 0, 1, 1, 2]); }
  removeMember() { return new Uint8Array([3]); }
  memberCount() { return 1; }
  encrypt(_g: Uint8Array, pt: Uint8Array) { return pt; }
  decrypt(_g: Uint8Array, ct: Uint8Array) { return ct; }
  processWelcome() { return new Uint8Array(16); }
  processCommit() {}
  free() {}
}

// Minimal JWT with tid + uid claims: header.payload.signature
const jwtPayload = btoa(JSON.stringify({ tid: "00".repeat(16), uid: "01".repeat(16) }));
const testToken = `eyJ0eXAiOiJKV1QifQ.${jwtPayload}.sig`;

const testConfig = {
  url: "ws://localhost:4000",
  token: testToken,
  MlsManager: MockMlsManager,
};

describe("MercuryClient", () => {
  test("starts disconnected", () => {
    const client = new MercuryClient(testConfig);
    expect(client.state).toBe("disconnected");
  });

  test("returns same channel instance for same id", () => {
    const client = new MercuryClient(testConfig);
    const ch1 = client.channel("general");
    const ch2 = client.channel("general");
    expect(ch1).toBe(ch2);
  });

  test("returns different channel instances for different ids", () => {
    const client = new MercuryClient(testConfig);
    const ch1 = client.channel("general");
    const ch2 = client.channel("random");
    expect(ch1).not.toBe(ch2);
  });

  test("disconnect clears channels", () => {
    const client = new MercuryClient(testConfig);
    client.channel("general");
    client.disconnect();
    expect(client.state).toBe("disconnected");
    const ch = client.channel("general");
    expect(ch).toBeDefined();
  });
});
