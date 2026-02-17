/** Configuration for creating a MercuryClient. */
export interface MercuryConfig {
  /** WebSocket gateway URL (e.g. "wss://gateway.example.com/ws"). */
  url: string;
  /** JWT authentication token containing tenant_id, user_id, device_id. */
  token: string;
}

/** A received or sent message. */
export interface Message {
  id: string;
  sender: string;
  content: string;
  contentType: number;
  timestamp: number;
}

/** Options for fetching message history. */
export interface HistoryOptions {
  limit?: number;
}

/** Connection state. */
export type ConnectionState =
  | "disconnected"
  | "connecting"
  | "connected";

/** Events emitted by a Channel. */
export type ChannelEvent = "message" | "typing" | "read" | "presence";

/** Callback for channel events. */
export type MessageHandler = (msg: Message) => void;
export type TypingHandler = (data: { userId: string }) => void;
export type ReadHandler = (data: { userId: string; messageId: string }) => void;
