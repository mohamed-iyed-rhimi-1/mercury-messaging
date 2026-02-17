@0xf1e2d3c4b5a69788;

# Lightweight events: typing, read receipts, MLS handshake, presence.
# These are small metadata payloads — capnp gives schema evolution + type safety.

struct TypingEvent {
  userId @0 :Data;               # 16 bytes UUID
}

struct ReadReceipt {
  userId    @0 :Data;            # 16 bytes UUID
  messageId @1 :Data;            # 16 bytes ULID
}

struct MlsKeyPackage {
  keyPackage @0 :Data;           # Opaque MLS KeyPackage bytes
}

struct MlsKeyPackageList {
  keyPackages @0 :List(Data);    # List of opaque KeyPackage bytes
}

struct MlsCommit {
  commit @0 :Data;               # Opaque MLS Commit bytes
}

struct MlsWelcome {
  welcome @0 :Data;              # Opaque MLS Welcome bytes
  userId  @1 :Data;              # 16 bytes — target user
}
