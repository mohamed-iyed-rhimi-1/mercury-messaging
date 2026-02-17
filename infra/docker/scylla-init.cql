-- Mercury ScyllaDB schema
-- Single source of truth: used by docker-compose AND k8s init job
-- Dev uses SimpleStrategy RF=1; production should use NetworkTopologyStrategy RF=3

CREATE KEYSPACE IF NOT EXISTS mercury
  WITH replication = {'class': 'SimpleStrategy', 'replication_factor': 1};

CREATE TABLE IF NOT EXISTS mercury.messages (
    tenant_id blob,
    channel_id blob,
    bucket_id int,
    message_id blob,
    sender_id blob,
    encrypted_content blob,
    content_type tinyint,
    reply_to blob,
    created_at bigint,
    server_received_at bigint,
    PRIMARY KEY ((tenant_id, channel_id, bucket_id), message_id)
) WITH CLUSTERING ORDER BY (message_id DESC)
  AND compaction = {'class': 'TimeWindowCompactionStrategy',
                    'compaction_window_size': 1,
                    'compaction_window_unit': 'DAYS'}
  AND gc_grace_seconds = 864000;

CREATE TABLE IF NOT EXISTS mercury.read_positions (
    tenant_id blob,
    user_id blob,
    channel_id blob,
    last_read_message_id blob,
    updated_at bigint,
    PRIMARY KEY ((tenant_id, user_id), channel_id)
);

CREATE TABLE IF NOT EXISTS mercury.channel_members (
    tenant_id blob,
    channel_id blob,
    user_id blob,
    role tinyint,
    joined_at timestamp,
    PRIMARY KEY ((tenant_id, channel_id), user_id)
);

CREATE TABLE IF NOT EXISTS mercury.reactions (
    tenant_id blob,
    channel_id blob,
    message_id blob,
    user_id blob,
    emoji text,
    created_at bigint,
    PRIMARY KEY ((tenant_id, channel_id, message_id), user_id, emoji)
);
