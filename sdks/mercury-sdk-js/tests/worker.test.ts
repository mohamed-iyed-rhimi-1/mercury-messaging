import { describe, test, expect } from "bun:test";
import { WasmBridge } from "../src/worker";
import type { WasmModule } from "../src/worker";

/** Mock WASM module for testing without actual WASM binary. */
const mockWasm: WasmModule = {
  generateMessageId: () => "01ABCDEFGHIJKLMNOPQRSTUVWX",
  computeTimeBucket: () => 1972,
  validateMessage: (content, contentType) =>
    content.length === 0 && contentType !== 5
      ? "content is empty for non-delete message"
      : "",
  validateDelta: (json) => {
    try { JSON.parse(json); return ""; } catch { return "invalid json"; }
  },
  validateDeltaBatch: (count) =>
    count === 0 ? "batch is empty" : count > 1000 ? "batch too large" : "",
  generateKeyPackage: (identity) => identity,
  default: async () => {},
};

describe("WasmBridge", () => {
  test("executes generateMessageId via mock module", async () => {
    const bridge = new WasmBridge();
    bridge.setWasmModule(mockWasm);
    const id = await bridge.exec({ cmd: "generateMessageId" });
    expect(id).toBe("01ABCDEFGHIJKLMNOPQRSTUVWX");
  });

  test("executes validateMessage via mock module", async () => {
    const bridge = new WasmBridge();
    bridge.setWasmModule(mockWasm);
    const result = await bridge.exec({
      cmd: "validateMessage",
      content: new Uint8Array([104, 101, 108, 108, 111]),
      contentType: 0,
    });
    expect(result).toBe("");
  });

  test("validateMessage rejects empty content", async () => {
    const bridge = new WasmBridge();
    bridge.setWasmModule(mockWasm);
    const result = await bridge.exec({
      cmd: "validateMessage",
      content: new Uint8Array(0),
      contentType: 0,
    });
    expect(result).toBe("content is empty for non-delete message");
  });

  test("throws if no WASM module loaded", async () => {
    const bridge = new WasmBridge();
    await bridge.waitReady();
    expect(bridge.exec({ cmd: "generateMessageId" })).rejects.toThrow(
      "WASM not loaded",
    );
  });

  test("validateDeltaBatch checks bounds", async () => {
    const bridge = new WasmBridge();
    bridge.setWasmModule(mockWasm);
    expect(await bridge.exec({ cmd: "validateDeltaBatch", count: 500 })).toBe("");
    expect(await bridge.exec({ cmd: "validateDeltaBatch", count: 0 })).toBe("batch is empty");
    expect(await bridge.exec({ cmd: "validateDeltaBatch", count: 1001 })).toBe("batch too large");
  });
});
