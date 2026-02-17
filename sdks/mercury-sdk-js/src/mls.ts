/**
 * MLS group manager for the JS SDK.
 * Wraps the WASM MlsManager class from mercury-sdk-core.
 *
 * Usage:
 *   const mls = new MlsClient(identity);
 *   mls.createGroup(channelId);
 *   const ciphertext = mls.encrypt(channelId, plaintext);
 *   const plaintext = mls.decrypt(channelId, ciphertext);
 */

// The WASM MlsManager type — imported dynamically to avoid hard dep on WASM load
type WasmMlsManager = {
  generateKeyPackage(): Uint8Array;
  createGroup(groupId: Uint8Array): void;
  addMember(groupId: Uint8Array, keyPackage: Uint8Array): Uint8Array;
  encrypt(groupId: Uint8Array, plaintext: Uint8Array): Uint8Array;
  decrypt(groupId: Uint8Array, ciphertext: Uint8Array): Uint8Array;
  processWelcome(welcome: Uint8Array): Uint8Array;
  processCommit(groupId: Uint8Array, commit: Uint8Array): void;
  free(): void;
};

type WasmMlsManagerConstructor = new (identity: Uint8Array) => WasmMlsManager;

/** Parsed result from addMember — commit + welcome packed as length-prefixed bytes. */
export interface AddMemberResult {
  commit: Uint8Array;
  welcome: Uint8Array;
}

/** Max messages before automatic key rotation. */
const KEY_ROTATION_THRESHOLD = 100;

export class MlsClient {
  private manager: WasmMlsManager;
  private messageCounts = new Map<string, number>();

  constructor(identity: Uint8Array, MlsManagerClass: WasmMlsManagerConstructor) {
    this.manager = new MlsManagerClass(identity);
  }

  /** Generate a fresh KeyPackage for upload to the server. */
  generateKeyPackage(): Uint8Array {
    return this.manager.generateKeyPackage();
  }

  /** Create a new MLS group for a channel. */
  createGroup(channelId: Uint8Array): void {
    this.manager.createGroup(channelId);
    this.messageCounts.set(toHex(channelId), 0);
  }

  /** Add a member to a group. Returns commit + welcome for relay. */
  addMember(channelId: Uint8Array, keyPackage: Uint8Array): AddMemberResult {
    const packed = this.manager.addMember(channelId, keyPackage);
    return unpackAddMember(packed);
  }

  /** Encrypt plaintext for a channel group. */
  encrypt(channelId: Uint8Array, plaintext: Uint8Array): Uint8Array {
    const ct = this.manager.encrypt(channelId, plaintext);
    const key = toHex(channelId);
    this.messageCounts.set(key, (this.messageCounts.get(key) ?? 0) + 1);
    return ct;
  }

  /** Decrypt MLS ciphertext from a channel group. */
  decrypt(channelId: Uint8Array, ciphertext: Uint8Array): Uint8Array {
    return this.manager.decrypt(channelId, ciphertext);
  }

  /** Join a group from a Welcome message. Returns the group_id. */
  processWelcome(welcome: Uint8Array): Uint8Array {
    const groupId = this.manager.processWelcome(welcome);
    this.messageCounts.set(toHex(groupId), 0);
    return groupId;
  }

  /** Process a Commit message (member add/remove/update). */
  processCommit(channelId: Uint8Array, commit: Uint8Array): void {
    this.manager.processCommit(channelId, commit);
  }

  /** Check if key rotation is needed for a channel. */
  needsRotation(channelId: Uint8Array): boolean {
    return (this.messageCounts.get(toHex(channelId)) ?? 0) >= KEY_ROTATION_THRESHOLD;
  }

  /** Reset message count after rotation. */
  resetRotationCounter(channelId: Uint8Array): void {
    this.messageCounts.set(toHex(channelId), 0);
  }

  /** Free WASM resources. */
  destroy(): void {
    this.manager.free();
  }
}

/** Unpack addMember result: [commit_len(4 BE), commit, welcome] */
function unpackAddMember(packed: Uint8Array): AddMemberResult {
  const view = new DataView(packed.buffer, packed.byteOffset, packed.byteLength);
  const commitLen = view.getUint32(0, false); // big-endian
  const commit = packed.slice(4, 4 + commitLen);
  const welcome = packed.slice(4 + commitLen);
  return { commit, welcome };
}

function toHex(bytes: Uint8Array): string {
  return Array.from(bytes, (b) => b.toString(16).padStart(2, "0")).join("");
}
