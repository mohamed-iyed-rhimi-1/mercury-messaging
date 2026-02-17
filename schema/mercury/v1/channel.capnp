@0xc1d2e3f4a5b6c7d8;

enum ChannelType {
  dm        @0;
  group     @1;
  broadcast @2;
}

struct Channel {
  tenantId    @0 :Data;          # 16 bytes UUID
  channelId   @1 :Data;          # 16 bytes UUID
  channelType @2 :ChannelType;
  name        @3 :Text;          # Optional, for groups/broadcasts
  createdBy   @4 :Data;          # 16 bytes UUID
  createdAt   @5 :UInt64;        # Unix millis
}

struct ChannelMember {
  tenantId  @0 :Data;
  channelId @1 :Data;
  userId    @2 :Data;
  role      @3 :UInt8;           # 0=member, 1=admin, 2=owner
  joinedAt  @4 :UInt64;
}
