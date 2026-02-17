@0xe1f2a3b4c5d6e7f8;

struct HybridLogicalClock {
  wallClockMs @0 :UInt64;        # Physical wall clock (Unix millis)
  counter     @1 :UInt32;        # Logical counter for same-ms events
  nodeId      @2 :Data;          # 16 bytes — unique node identifier
}

struct SyncRequest {
  tenantId     @0 :Data;
  channelId    @1 :Data;
  deviceId     @2 :Data;
  lastKnownHlc @3 :HybridLogicalClock;
  maxDeltas    @4 :UInt32;       # Bounded: max 10,000 (NASA Rule #2)
}

struct SyncResponse {
  deltas            @0 :List(CRDTDelta);
  newHlc            @1 :HybridLogicalClock;
  hasMore           @2 :Bool;    # Pagination: more deltas available
  continuationToken @3 :Data;    # Opaque token for next page
}

struct CRDTDelta {
  hlc @0 :HybridLogicalClock;   # When this delta was created
  union {
    messageAppend      @1 :Data; # Encrypted message bytes
    messageEdit        @2 :Data; # Encrypted edit payload
    messageDelete      @3 :Data; # ULID of deleted message
    reactionAdd        @4 :ReactionDelta;
    reactionRemove     @5 :ReactionDelta;
    memberAdd          @6 :MemberDelta;
    memberRemove       @7 :MemberDelta;
    readPositionUpdate @8 :ReadPositionDelta;
  }
}

struct ReactionDelta {
  messageId @0 :Data;            # ULID of target message
  userId    @1 :Data;
  emoji     @2 :Text;
}

struct MemberDelta {
  channelId @0 :Data;
  userId    @1 :Data;
  role      @2 :UInt8;
}

struct ReadPositionDelta {
  channelId        @0 :Data;
  userId           @1 :Data;
  lastReadMessageId @2 :Data;   # ULID
}
