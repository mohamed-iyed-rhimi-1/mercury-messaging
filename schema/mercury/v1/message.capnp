@0xa1b2c3d4e5f6a7b8;

enum ContentType {
  text     @0;
  image    @1;
  file     @2;
  reaction @3;
  edit     @4;
  delete   @5;
}

struct MessageMetadata {
  contentType @0 :ContentType;
  replyTo     @1 :Data;          # Optional ULID of parent message
  editOf      @2 :Data;          # Optional ULID of original (for edits)
}

struct FileAttachment {
  fileId        @0 :Text;
  encryptedUrl  @1 :Text;
  encryptionKey @2 :Data;        # Per-file AES-256-GCM key (encrypted with MLS group key)
  encryptionIv  @3 :Data;
  mimeType      @4 :Text;
  sizeBytes     @5 :UInt64;
  thumbnail     @6 :Thumbnail;
}

struct Thumbnail {
  url    @0 :Text;
  width  @1 :UInt32;
  height @2 :UInt32;
}

struct Reaction {
  targetMessageId @0 :Data;      # ULID of message being reacted to
  emoji           @1 :Text;      # Unicode emoji or custom ID
  remove          @2 :Bool;      # true = remove reaction, false = add
}

struct MessagePayload {
  # Decrypted inner content (only visible to clients, never to server)
  metadata    @0 :MessageMetadata;
  union {
    text       @1 :Text;
    file       @2 :FileAttachment;
    reaction   @3 :Reaction;
    edit       @4 :Text;         # New content for edited message
    delete     @5 :Void;         # Tombstone
  }
}
