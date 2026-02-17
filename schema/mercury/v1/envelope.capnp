@0xb7c5f0e1a2d3f4e5;

struct Envelope {
  # Outer wire format — routing info only, no plaintext content.
  # Server reads this to route; inner payload is E2EE.
  tenantId  @0 :Data;       # 16 bytes UUID
  channelId @1 :Data;       # 16 bytes UUID
  senderId  @2 :Data;       # 16 bytes UUID (cleared by sealed sender)
  messageId @3 :Data;       # 16 bytes ULID
  timestamp @4 :UInt64;     # Unix millis
  payload   @5 :Data;       # Encrypted MLS ciphertext (opaque to server)
}
