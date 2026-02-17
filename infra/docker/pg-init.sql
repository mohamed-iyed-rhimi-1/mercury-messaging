-- Mercury PostgreSQL schema
-- Single source of truth: used by docker-compose AND k8s init job
-- Citus-ready composite PKs (tenant_id first)

\c mercury_dev
CREATE EXTENSION IF NOT EXISTS citus;
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";

CREATE TABLE IF NOT EXISTS tenants (
    tenant_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    name TEXT NOT NULL CHECK (char_length(name) BETWEEN 1 AND 128),
    plan TEXT NOT NULL CHECK (plan IN ('free', 'pro', 'enterprise')) DEFAULT 'free',
    max_users INT NOT NULL DEFAULT 1000,
    max_channels INT NOT NULL DEFAULT 100,
    rate_limit_per_user INT NOT NULL DEFAULT 100,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS users (
    user_id UUID NOT NULL DEFAULT gen_random_uuid(),
    tenant_id UUID NOT NULL REFERENCES tenants(tenant_id),
    display_name TEXT NOT NULL CHECK (char_length(display_name) BETWEEN 1 AND 64),
    avatar_url TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (tenant_id, user_id)
);

CREATE TABLE IF NOT EXISTS devices (
    device_id UUID NOT NULL DEFAULT gen_random_uuid(),
    tenant_id UUID NOT NULL REFERENCES tenants(tenant_id),
    user_id UUID NOT NULL,
    device_name TEXT NOT NULL,
    platform TEXT NOT NULL CHECK (platform IN ('ios', 'android', 'web', 'desktop')),
    push_token TEXT,
    mls_key_package BYTEA,
    last_seen_at TIMESTAMPTZ,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (tenant_id, device_id),
    FOREIGN KEY (tenant_id, user_id) REFERENCES users(tenant_id, user_id)
);

CREATE TABLE IF NOT EXISTS channels (
    channel_id UUID NOT NULL DEFAULT gen_random_uuid(),
    tenant_id UUID NOT NULL REFERENCES tenants(tenant_id),
    channel_type SMALLINT NOT NULL CHECK (channel_type IN (0, 1, 2)),
    name TEXT CHECK (char_length(name) <= 128),
    created_by UUID NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (tenant_id, channel_id),
    FOREIGN KEY (tenant_id, created_by) REFERENCES users(tenant_id, user_id)
);

CREATE TABLE IF NOT EXISTS channel_members (
    tenant_id UUID NOT NULL REFERENCES tenants(tenant_id),
    channel_id UUID NOT NULL,
    user_id UUID NOT NULL,
    role SMALLINT NOT NULL DEFAULT 0 CHECK (role IN (0, 1, 2)),
    joined_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (tenant_id, channel_id, user_id),
    FOREIGN KEY (tenant_id, channel_id) REFERENCES channels(tenant_id, channel_id),
    FOREIGN KEY (tenant_id, user_id) REFERENCES users(tenant_id, user_id)
);

CREATE TABLE IF NOT EXISTS sync_cursors (
    tenant_id UUID NOT NULL,
    user_id UUID NOT NULL,
    device_id UUID NOT NULL,
    channel_id UUID NOT NULL,
    last_hlc_wall BIGINT NOT NULL DEFAULT 0,
    last_hlc_counter INT NOT NULL DEFAULT 0,
    last_hlc_node BYTEA NOT NULL DEFAULT '\x00',
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (tenant_id, user_id, device_id, channel_id)
);
