/**
 * MLS group manager for the JS SDK.
 *
 * Uses MLS for group key management and a stable AES-256-GCM channel
 * encryption key (CEK) for message encryption. The CEK is distributed
 * to new members via MLS-encrypted application messages after Welcome.
 *
 * This dual-layer approach means:
 * - MLS handles: identity, key exchange, member add/remove, forward secrecy on CEK rotation
 * - CEK handles: message encryption — stable across epochs so history is decryptable
 * - CEK is rotated on member removal (post-compromise security)
 */

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

export interface AddMemberResult {
  commit: Uint8Array;
  welcome: Uint8Array;
}

/** AES-256-GCM: 12-byte IV + ciphertext + 16-byte tag */
const IV_LEN = 12;
const CEK_LEN = 32;

/** CEK message prefix — distinguishes CEK distribution from normal messages */
const CEK_PREFIX = new Uint8Array([0x4D, 0x43, 0x45, 0x4B]); // "MCEK"

export class MlsClient {
  private manager: WasmMlsManager;
  private channelKeys = new Map<string, CryptoKey>();
  private rawCeks = new Map<string, Uint8Array>();

  constructor(identity: Uint8Array, MlsManagerClass: WasmMlsManagerConstructor) {
    this.manager = new MlsManagerClass(identity);
  }

  generateKeyPackage(): Uint8Array {
    return this.manager.generateKeyPackage();
  }

  /** Create a new MLS group and generate a fresh CEK. */
  async createGroup(channelId: Uint8Array): Promise<void> {
    this.manager.createGroup(channelId);
    const rawKey = crypto.getRandomValues(new Uint8Array(CEK_LEN));
    await this.importCek(channelId, rawKey);
  }

  addMember(channelId: Uint8Array, keyPackage: Uint8Array): AddMemberResult {
    const packed = this.manager.addMember(channelId, keyPackage);
    return unpackAddMember(packed);
  }

  /**
   * Encrypt the CEK using MLS for delivery to a new member.
   * Called by the group creator after addMember, sent as a separate message.
   */
  encryptCekForMember(channelId: Uint8Array): Uint8Array {
    const raw = this.rawCeks.get(toHex(channelId));
    if (!raw) throw new Error("No CEK for channel");
    // Prefix + raw CEK, encrypted via MLS
    const payload = new Uint8Array(CEK_PREFIX.length + raw.length);
    payload.set(CEK_PREFIX, 0);
    payload.set(raw, CEK_PREFIX.length);
    return this.manager.encrypt(channelId, payload);
  }

  /**
   * Try to decrypt an MLS message as a CEK distribution.
   * Returns true if it was a CEK message (and imports the key), false otherwise.
   */
  async tryDecryptCek(channelId: Uint8Array, ciphertext: Uint8Array): Promise<boolean> {
    let plaintext: Uint8Array;
    try {
      plaintext = this.manager.decrypt(channelId, ciphertext);
    } catch {
      return false;
    }
    if (plaintext.length === CEK_PREFIX.length + CEK_LEN &&
        plaintext[0] === CEK_PREFIX[0] && plaintext[1] === CEK_PREFIX[1] &&
        plaintext[2] === CEK_PREFIX[2] && plaintext[3] === CEK_PREFIX[3]) {
      const rawKey = plaintext.slice(CEK_PREFIX.length);
      await this.importCek(channelId, rawKey);
      return true;
    }
    return false;
  }

  /** Encrypt plaintext with the channel's AES-256-GCM CEK. */
  async encrypt(channelId: Uint8Array, plaintext: Uint8Array): Promise<Uint8Array> {
    const key = this.channelKeys.get(toHex(channelId));
    if (!key) throw new Error("No CEK for channel — MLS handshake incomplete");
    const iv = crypto.getRandomValues(new Uint8Array(IV_LEN));
    const ct = await crypto.subtle.encrypt({ name: "AES-GCM", iv }, key, plaintext as unknown as ArrayBuffer);
    // Pack: <<iv:12, ciphertext+tag>>
    const out = new Uint8Array(IV_LEN + ct.byteLength);
    out.set(iv, 0);
    out.set(new Uint8Array(ct), IV_LEN);
    return out;
  }

  /** Decrypt AES-256-GCM ciphertext with the channel's CEK. */
  async decrypt(channelId: Uint8Array, ciphertext: Uint8Array): Promise<Uint8Array> {
    const key = this.channelKeys.get(toHex(channelId));
    if (!key) throw new Error("No CEK for channel");
    if (ciphertext.length < IV_LEN + 16) throw new Error("Ciphertext too short");
    const iv = ciphertext.slice(0, IV_LEN);
    const ct = ciphertext.slice(IV_LEN);
    const pt = await crypto.subtle.decrypt({ name: "AES-GCM", iv }, key, ct as unknown as ArrayBuffer);
    return new Uint8Array(pt);
  }

  hasCek(channelId: Uint8Array): boolean {
    return this.channelKeys.has(toHex(channelId));
  }

  processWelcome(welcome: Uint8Array): Uint8Array {
    const groupId = this.manager.processWelcome(welcome);
    return groupId;
  }

  processCommit(channelId: Uint8Array, commit: Uint8Array): void {
    this.manager.processCommit(channelId, commit);
  }

  /** Free WASM resources. */
  destroy(): void {
    this.manager.free();
  }

  private async importCek(channelId: Uint8Array, rawKey: Uint8Array): Promise<void> {
    const key = await crypto.subtle.importKey(
      "raw", rawKey as unknown as ArrayBuffer, { name: "AES-GCM" }, false, ["encrypt", "decrypt"],
    );
    const hex = toHex(channelId);
    this.channelKeys.set(hex, key);
    this.rawCeks.set(hex, new Uint8Array(rawKey));
  }
}

function unpackAddMember(packed: Uint8Array): AddMemberResult {
  const view = new DataView(packed.buffer, packed.byteOffset, packed.byteLength);
  const commitLen = view.getUint32(0, false);
  const commit = packed.slice(4, 4 + commitLen);
  const welcome = packed.slice(4 + commitLen);
  return { commit, welcome };
}

function toHex(bytes: Uint8Array): string {
  return Array.from(bytes, (b) => b.toString(16).padStart(2, "0")).join("");
}
