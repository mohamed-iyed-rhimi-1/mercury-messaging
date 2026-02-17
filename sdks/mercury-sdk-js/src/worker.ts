/**
 * Web Worker wrapper for WASM core.
 * Keeps crypto and validation off the main thread.
 *
 * Falls back to main-thread execution if Workers are unavailable.
 */

export interface WasmModule {
  generateMessageId(): string;
  computeTimeBucket(timestampMs: bigint): number;
  validateMessage(content: Uint8Array, contentType: number): string;
  validateDelta(deltaJson: string): string;
  validateDeltaBatch(count: number): string;
  generateKeyPackage(identity: Uint8Array): Uint8Array;
  default(): Promise<void>;
}

export type WorkerCommand =
  | { cmd: "generateMessageId" }
  | { cmd: "computeTimeBucket"; timestampMs: number }
  | { cmd: "validateMessage"; content: Uint8Array; contentType: number }
  | { cmd: "validateDelta"; deltaJson: string }
  | { cmd: "validateDeltaBatch"; count: number }
  | { cmd: "generateKeyPackage"; identity: Uint8Array };

export type WorkerResponse =
  | { id: number; result: unknown }
  | { id: number; error: string };

/**
 * Proxy that sends commands to a Web Worker running the WASM module,
 * or executes directly on the main thread as fallback.
 */
export class WasmBridge {
  private worker: Worker | null = null;
  private wasmModule: WasmModule | null = null;
  private pending = new Map<number, { resolve: (v: unknown) => void; reject: (e: Error) => void }>();
  private nextId = 0;
  private ready: Promise<void>;

  constructor(wasmUrl?: string) {
    this.ready = this.init(wasmUrl);
  }

  private async init(wasmUrl?: string): Promise<void> {
    if (typeof Worker !== "undefined" && wasmUrl) {
      try {
        this.worker = new Worker(wasmUrl, { type: "module" });
        this.worker.onmessage = (e: MessageEvent<WorkerResponse>) => {
          const msg = e.data;
          const p = this.pending.get(msg.id);
          if (p) {
            this.pending.delete(msg.id);
            if ("error" in msg) p.reject(new Error(msg.error));
            else p.resolve(msg.result);
          }
        };
        return;
      } catch {
        // Fall through to main-thread
      }
    }

    // Fallback: load WASM on main thread via dynamic import
    // The consumer must provide the WASM module via setWasmModule() in non-browser envs
  }

  /** Manually set the WASM module (for testing or non-browser environments). */
  setWasmModule(mod: WasmModule): void {
    this.wasmModule = mod;
  }

  async waitReady(): Promise<void> {
    await this.ready;
  }

  async exec(command: WorkerCommand): Promise<unknown> {
    await this.ready;
    if (this.worker) return this.execWorker(command);
    if (this.wasmModule) return this.execLocal(command);
    throw new Error("WASM not loaded: call setWasmModule() or provide a worker URL");
  }

  private execWorker(command: WorkerCommand): Promise<unknown> {
    return new Promise((resolve, reject) => {
      const id = this.nextId++;
      this.pending.set(id, { resolve, reject });
      this.worker!.postMessage({ id, ...command });
    });
  }

  private execLocal(command: WorkerCommand): unknown {
    const wasm = this.wasmModule!;
    switch (command.cmd) {
      case "generateMessageId":
        return wasm.generateMessageId();
      case "computeTimeBucket":
        return wasm.computeTimeBucket(BigInt(command.timestampMs));
      case "validateMessage":
        return wasm.validateMessage(command.content, command.contentType);
      case "validateDelta":
        return wasm.validateDelta(command.deltaJson);
      case "validateDeltaBatch":
        return wasm.validateDeltaBatch(command.count);
      case "generateKeyPackage":
        return wasm.generateKeyPackage(command.identity);
    }
  }

  terminate(): void {
    this.worker?.terminate();
    this.worker = null;
  }
}
