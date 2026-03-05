/**
 * Binary frame codec for the Mercury wire protocol.
 *
 * Frame format: <<type:8, ref:32LE, topicId:16LE, payload...>>
 *
 * Frame types:
 *   0x01 Join      payload: topic string (utf8)
 *   0x02 Leave     payload: empty
 *   0x03 Reply     payload: <<status:8, data...>>
 *   0x04 Push      payload: <<event:8, data...>>
 *   0x05 Broadcast payload: <<event:8, data...>>
 *   0x06 Heartbeat payload: empty
 */

// Frame types
export const FRAME_JOIN = 0x01;
export const FRAME_REPLY = 0x03;
export const FRAME_PUSH = 0x04;
export const FRAME_BROADCAST = 0x05;
export const FRAME_HEARTBEAT = 0x06;

// Status bytes
export const STATUS_OK = 0x00;
export const STATUS_ERROR = 0x01;

// Event bytes
export const EV_MSG_SEND = 0x01;
export const EV_MSG_NEW = 0x02;
export const EV_MSG_HISTORY = 0x03;
export const EV_MSG_TYPING = 0x04;
export const EV_MSG_READ = 0x05;
export const EV_MLS_KEY_PACKAGE = 0x06;
export const EV_MLS_FETCH_KP = 0x07;
export const EV_MLS_COMMIT = 0x08;
export const EV_MLS_WELCOME = 0x09;
export const EV_MLS_REMOVE = 0x0a;
export const EV_SYNC_REQUEST = 0x0b;
export const EV_SYNC_PUSH = 0x0c;
export const EV_SYNC_CURSOR = 0x0d;
export const EV_CH_CREATE = 0x0e;
export const EV_PRESENCE_JOIN = 0x0f;
export const EV_MLS_MEMBERS = 0x12;
export const EV_MLS_GROUP_INFO = 0x13;
export const EV_MLS_CEK = 0x14;

const HEADER_SIZE = 7; // 1 + 4 + 2

export function encodeFrame(
  type: number,
  ref: number,
  topicId: number,
  payload: Uint8Array = new Uint8Array(0),
): Uint8Array {
  const buf = new Uint8Array(HEADER_SIZE + payload.length);
  const view = new DataView(buf.buffer);
  buf[0] = type;
  view.setUint32(1, ref, true);
  view.setUint16(5, topicId, true);
  buf.set(payload, HEADER_SIZE);
  return buf;
}

export function decodeFrame(data: Uint8Array): {
  type: number;
  ref: number;
  topicId: number;
  payload: Uint8Array;
} {
  const view = new DataView(data.buffer, data.byteOffset, data.byteLength);
  return {
    type: data[0],
    ref: view.getUint32(1, true),
    topicId: view.getUint16(5, true),
    payload: data.subarray(HEADER_SIZE),
  };
}

/** Pack multiple binary blobs: <<count:32LE, len1:32LE, blob1, len2:32LE, blob2, ...>> */
export function packEnvelopes(envelopes: Uint8Array[]): Uint8Array {
  let totalLen = 4; // count
  for (const e of envelopes) totalLen += 4 + e.length;
  const buf = new Uint8Array(totalLen);
  const view = new DataView(buf.buffer);
  view.setUint32(0, envelopes.length, true);
  let offset = 4;
  for (const e of envelopes) {
    view.setUint32(offset, e.length, true);
    buf.set(e, offset + 4);
    offset += 4 + e.length;
  }
  return buf;
}

/** Unpack binary blobs from packed format. */
export function unpackEnvelopes(data: Uint8Array): Uint8Array[] {
  if (data.length < 4) return [];
  const view = new DataView(data.buffer, data.byteOffset, data.byteLength);
  const count = view.getUint32(0, true);
  const out: Uint8Array[] = [];
  let offset = 4;
  for (let i = 0; i < count && offset < data.length; i++) {
    const len = view.getUint32(offset, true);
    out.push(data.subarray(offset + 4, offset + 4 + len));
    offset += 4 + len;
  }
  return out;
}
