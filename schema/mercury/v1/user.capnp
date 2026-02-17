@0xd1e2f3a4b5c6d7e8;

struct User {
  tenantId    @0 :Data;          # 16 bytes UUID
  userId      @1 :Data;          # 16 bytes UUID
  displayName @2 :Text;
  avatarUrl   @3 :Text;
  role        @4 :UInt8;         # 0=user, 1=moderator, 2=admin, 3=owner
  createdAt   @5 :UInt64;
}

struct Device {
  tenantId      @0 :Data;
  deviceId      @1 :Data;
  userId        @2 :Data;
  deviceName    @3 :Text;
  platform      @4 :Text;       # "ios", "android", "web"
  pushToken     @5 :Text;       # APNs/FCM token
  mlsKeyPackage @6 :Data;       # MLS KeyPackage bytes
  lastSeenAt    @7 :UInt64;
}

struct AuthToken {
  tenantId  @0 :Data;
  userId    @1 :Data;
  deviceId  @2 :Data;
  expiresAt @3 :UInt64;
  scopes    @4 :List(Text);
}
