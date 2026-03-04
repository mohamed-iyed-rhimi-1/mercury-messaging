#![doc = "Rustler NIFs bridging mercury-core/crdt/crypto into Elixir."]

use mercury_core::{
    ChannelId, ChannelType, ContentType, Message, MessageId, TenantId, TimeBucket, UserId,
};
use mercury_crdt::Hlc;
use rustler::{Atom, Binary, Env, NewBinary, NifResult, ResourceArc};

mod atoms {
    rustler::atoms! {
        ok,
        error,
        invalid_message,
        invalid_channel,
        invalid_content_type,
        invalid_channel_type,
        bad_length,
    }
}

// ---------------------------------------------------------------------------
// ID generation
// ---------------------------------------------------------------------------

#[rustler::nif]
fn generate_message_id(env: Env) -> Binary {
    let id = MessageId::new();
    let bytes = id.as_bytes();
    let mut bin = NewBinary::new(env, 16);
    bin.as_mut_slice().copy_from_slice(&bytes);
    bin.into()
}

#[rustler::nif]
fn generate_channel_id(env: Env) -> Binary {
    let id = ChannelId::new();
    let mut bin = NewBinary::new(env, 16);
    bin.as_mut_slice().copy_from_slice(id.as_bytes());
    bin.into()
}

// ---------------------------------------------------------------------------
// Time bucket
// ---------------------------------------------------------------------------

#[rustler::nif]
fn compute_time_bucket(timestamp_ms: u64) -> u32 {
    TimeBucket::from_timestamp_ms(timestamp_ms).as_u32()
}

// ---------------------------------------------------------------------------
// Validation
// ---------------------------------------------------------------------------

fn parse_content_type(ct: u8) -> NifResult<ContentType> {
    match ct {
        0 => Ok(ContentType::Text),
        1 => Ok(ContentType::Image),
        2 => Ok(ContentType::File),
        3 => Ok(ContentType::Reaction),
        4 => Ok(ContentType::Edit),
        5 => Ok(ContentType::Delete),
        _ => Err(rustler::Error::Term(
            Box::new(atoms::invalid_content_type()),
        )),
    }
}

fn parse_uuid_16(bin: Binary) -> NifResult<[u8; 16]> {
    let slice = bin.as_slice();
    <[u8; 16]>::try_from(slice).map_err(|_| rustler::Error::Term(Box::new(atoms::bad_length())))
}

#[rustler::nif]
fn validate_message(
    tenant_id: Binary,
    channel_id: Binary,
    sender_id: Binary,
    content: Binary,
    content_type: u8,
) -> (Atom, Atom) {
    let Ok(ct) = parse_content_type(content_type) else {
        return (atoms::error(), atoms::invalid_content_type());
    };
    let Ok(tid) = parse_uuid_16(tenant_id) else {
        return (atoms::error(), atoms::invalid_message());
    };
    let Ok(cid) = parse_uuid_16(channel_id) else {
        return (atoms::error(), atoms::invalid_message());
    };
    let Ok(sid) = parse_uuid_16(sender_id) else {
        return (atoms::error(), atoms::invalid_message());
    };
    let msg = Message {
        tenant_id: TenantId::from_bytes(tid),
        channel_id: ChannelId::from_bytes(cid),
        id: MessageId::new(),
        sender_id: UserId::from_bytes(sid),
        encrypted_content: bytes::Bytes::from(content.as_slice().to_vec()),
        content_type: ct,
        reply_to: None,
        created_at: u64::try_from(
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .expect("clock")
                .as_millis(),
        )
        .expect("timestamp fits u64"),
        edited_at: None,
        server_received_at: None,
    };
    match msg.validate() {
        Ok(()) => (atoms::ok(), atoms::ok()),
        Err(_e) => (atoms::error(), atoms::invalid_message()),
    }
}

fn parse_channel_type(ct: u8) -> NifResult<ChannelType> {
    match ct {
        0 => Ok(ChannelType::Dm),
        1 => Ok(ChannelType::Group),
        2 => Ok(ChannelType::Broadcast),
        _ => Err(rustler::Error::Term(
            Box::new(atoms::invalid_channel_type()),
        )),
    }
}

#[rustler::nif]
fn validate_channel(
    tenant_id: Binary,
    channel_type: u8,
    name: Option<String>,
) -> (Atom, Atom) {
    let Ok(ct) = parse_channel_type(channel_type) else {
        return (atoms::error(), atoms::invalid_channel_type());
    };
    let Ok(tid) = parse_uuid_16(tenant_id) else {
        return (atoms::error(), atoms::invalid_channel());
    };
    let ch = mercury_core::Channel {
        tenant_id: TenantId::from_bytes(tid),
        id: ChannelId::new(),
        channel_type: ct,
        name,
        member_ids: vec![],
        created_by: UserId::new(),
        created_at: 1,
    };
    match ch.validate() {
        Ok(()) => (atoms::ok(), atoms::ok()),
        Err(_e) => (atoms::error(), atoms::invalid_channel()),
    }
}

// ---------------------------------------------------------------------------
// HLC — runs on dirty CPU scheduler to avoid blocking BEAM
// ---------------------------------------------------------------------------

#[rustler::nif(schedule = "DirtyCpu")]
fn hlc_tick(wall_clock_ms: u64, counter: u32, node_id: Binary) -> NifResult<(u64, u32)> {
    let mut hlc = Hlc {
        wall_clock_ms,
        counter,
        node_id: parse_uuid_16(node_id)?,
    };
    hlc.tick();
    Ok((hlc.wall_clock_ms, hlc.counter))
}

#[rustler::nif(schedule = "DirtyCpu")]
fn hlc_merge(
    local_wall: u64,
    local_counter: u32,
    local_node: Binary,
    remote_wall: u64,
    remote_counter: u32,
    remote_node: Binary,
) -> NifResult<(u64, u32)> {
    let mut local = Hlc {
        wall_clock_ms: local_wall,
        counter: local_counter,
        node_id: parse_uuid_16(local_node)?,
    };
    let remote = Hlc {
        wall_clock_ms: remote_wall,
        counter: remote_counter,
        node_id: parse_uuid_16(remote_node)?,
    };
    local.merge(&remote);
    Ok((local.wall_clock_ms, local.counter))
}

// ---------------------------------------------------------------------------
// MLS Group Manager — held as ResourceArc across NIF calls
// ResourceArc is passed by value per Rustler convention.
// ---------------------------------------------------------------------------

use mercury_crypto::mls::MlsGroupManager;
use std::sync::Mutex;

#[allow(dead_code)]
pub struct MlsManagerResource(Mutex<MlsGroupManager>);

#[rustler::resource_impl]
impl rustler::Resource for MlsManagerResource {}

#[allow(clippy::needless_pass_by_value)]
#[rustler::nif(schedule = "DirtyCpu")]
fn mls_create_identity(identity: Binary) -> NifResult<(Atom, ResourceArc<MlsManagerResource>)> {
    let mgr = MlsGroupManager::new(identity.as_slice())
        .map_err(|e| rustler::Error::Term(Box::new(e.to_string())))?;
    Ok((
        atoms::ok(),
        ResourceArc::new(MlsManagerResource(Mutex::new(mgr))),
    ))
}

#[allow(clippy::needless_pass_by_value)]
#[rustler::nif(schedule = "DirtyCpu")]
fn mls_generate_key_package(
    env: Env,
    resource: ResourceArc<MlsManagerResource>,
) -> NifResult<(Atom, Binary)> {
    let mgr = resource
        .0
        .lock()
        .map_err(|_| rustler::Error::Term(Box::new("lock poisoned")))?;
    let kp = mgr
        .generate_key_package()
        .map_err(|e| rustler::Error::Term(Box::new(e.to_string())))?;
    let mut bin = NewBinary::new(env, kp.len());
    bin.as_mut_slice().copy_from_slice(&kp);
    Ok((atoms::ok(), bin.into()))
}

#[allow(clippy::needless_pass_by_value)]
#[rustler::nif(schedule = "DirtyCpu")]
fn mls_create_group(
    resource: ResourceArc<MlsManagerResource>,
    group_id: Binary,
) -> NifResult<Atom> {
    let mut mgr = resource
        .0
        .lock()
        .map_err(|_| rustler::Error::Term(Box::new("lock poisoned")))?;
    mgr.create_group(group_id.as_slice())
        .map_err(|e| rustler::Error::Term(Box::new(e.to_string())))?;
    Ok(atoms::ok())
}

#[allow(clippy::needless_pass_by_value)]
#[rustler::nif(schedule = "DirtyCpu")]
fn mls_add_member<'a>(
    env: Env<'a>,
    resource: ResourceArc<MlsManagerResource>,
    group_id: Binary,
    key_package: Binary,
) -> NifResult<(Atom, Binary<'a>, Binary<'a>)> {
    let mut mgr = resource
        .0
        .lock()
        .map_err(|_| rustler::Error::Term(Box::new("lock poisoned")))?;
    let (commit, welcome) = mgr
        .add_member(group_id.as_slice(), key_package.as_slice())
        .map_err(|e| rustler::Error::Term(Box::new(e.to_string())))?;

    let mut commit_bin = NewBinary::new(env, commit.len());
    commit_bin.as_mut_slice().copy_from_slice(&commit);
    let mut welcome_bin = NewBinary::new(env, welcome.len());
    welcome_bin.as_mut_slice().copy_from_slice(&welcome);

    Ok((atoms::ok(), commit_bin.into(), welcome_bin.into()))
}

#[allow(clippy::needless_pass_by_value)]
#[rustler::nif(schedule = "DirtyCpu")]
fn mls_encrypt<'a>(
    env: Env<'a>,
    resource: ResourceArc<MlsManagerResource>,
    group_id: Binary,
    plaintext: Binary,
) -> NifResult<(Atom, Binary<'a>)> {
    let mut mgr = resource
        .0
        .lock()
        .map_err(|_| rustler::Error::Term(Box::new("lock poisoned")))?;
    let ct = mgr
        .encrypt(group_id.as_slice(), plaintext.as_slice())
        .map_err(|e| rustler::Error::Term(Box::new(e.to_string())))?;
    let mut bin = NewBinary::new(env, ct.len());
    bin.as_mut_slice().copy_from_slice(&ct);
    Ok((atoms::ok(), bin.into()))
}

#[allow(clippy::needless_pass_by_value)]
#[rustler::nif(schedule = "DirtyCpu")]
fn mls_decrypt<'a>(
    env: Env<'a>,
    resource: ResourceArc<MlsManagerResource>,
    group_id: Binary,
    ciphertext: Binary,
) -> NifResult<(Atom, Binary<'a>)> {
    let mut mgr = resource
        .0
        .lock()
        .map_err(|_| rustler::Error::Term(Box::new("lock poisoned")))?;
    let pt = mgr
        .decrypt(group_id.as_slice(), ciphertext.as_slice())
        .map_err(|e| rustler::Error::Term(Box::new(e.to_string())))?;
    let mut bin = NewBinary::new(env, pt.len());
    bin.as_mut_slice().copy_from_slice(&pt);
    Ok((atoms::ok(), bin.into()))
}

#[allow(clippy::needless_pass_by_value)]
#[rustler::nif(schedule = "DirtyCpu")]
fn mls_process_welcome<'a>(
    env: Env<'a>,
    resource: ResourceArc<MlsManagerResource>,
    welcome: Binary,
) -> NifResult<(Atom, Binary<'a>)> {
    let mut mgr = resource
        .0
        .lock()
        .map_err(|_| rustler::Error::Term(Box::new("lock poisoned")))?;
    let gid = mgr
        .process_welcome(welcome.as_slice())
        .map_err(|e| rustler::Error::Term(Box::new(e.to_string())))?;
    let mut bin = NewBinary::new(env, gid.len());
    bin.as_mut_slice().copy_from_slice(&gid);
    Ok((atoms::ok(), bin.into()))
}

#[allow(clippy::needless_pass_by_value)]
#[rustler::nif(schedule = "DirtyCpu")]
fn mls_process_commit(
    resource: ResourceArc<MlsManagerResource>,
    group_id: Binary,
    commit: Binary,
) -> NifResult<Atom> {
    let mut mgr = resource
        .0
        .lock()
        .map_err(|_| rustler::Error::Term(Box::new("lock poisoned")))?;
    mgr.process_commit(group_id.as_slice(), commit.as_slice())
        .map_err(|e| rustler::Error::Term(Box::new(e.to_string())))?;
    Ok(atoms::ok())
}

// ---------------------------------------------------------------------------
// NIF init — rustler 0.37 auto-discovers #[rustler::nif] functions
// ---------------------------------------------------------------------------

// ---------------------------------------------------------------------------
// Cap'n Proto envelope encode/decode
// ---------------------------------------------------------------------------

#[rustler::nif]
fn envelope_encode<'a>(
    env: Env<'a>,
    tenant_id: Binary,
    channel_id: Binary,
    sender_id: Binary,
    message_id: Binary,
    timestamp: u64,
    payload: Binary,
) -> Binary<'a> {
    let bytes = mercury_core::envelope_encode(
        tenant_id.as_slice(),
        channel_id.as_slice(),
        sender_id.as_slice(),
        message_id.as_slice(),
        timestamp,
        payload.as_slice(),
    );
    let mut bin = NewBinary::new(env, bytes.len());
    bin.as_mut_slice().copy_from_slice(&bytes);
    bin.into()
}

#[rustler::nif]
fn envelope_decode<'a>(
    env: Env<'a>,
    data: Binary,
) -> NifResult<(
    Binary<'a>,
    Binary<'a>,
    Binary<'a>,
    Binary<'a>,
    u64,
    Binary<'a>,
)> {
    let decoded = mercury_core::envelope_decode(data.as_slice())
        .map_err(|e| rustler::Error::Term(Box::new(e.to_string())))?;

    let mut tid = NewBinary::new(env, decoded.tenant_id.len());
    tid.as_mut_slice().copy_from_slice(&decoded.tenant_id);
    let mut cid = NewBinary::new(env, decoded.channel_id.len());
    cid.as_mut_slice().copy_from_slice(&decoded.channel_id);
    let mut sid = NewBinary::new(env, decoded.sender_id.len());
    sid.as_mut_slice().copy_from_slice(&decoded.sender_id);
    let mut mid = NewBinary::new(env, decoded.message_id.len());
    mid.as_mut_slice().copy_from_slice(&decoded.message_id);
    let mut pl = NewBinary::new(env, decoded.payload.len());
    pl.as_mut_slice().copy_from_slice(&decoded.payload);

    Ok((
        tid.into(),
        cid.into(),
        sid.into(),
        mid.into(),
        decoded.timestamp,
        pl.into(),
    ))
}

// ── Event NIFs ──

fn bytes_to_binary<'a>(env: Env<'a>, bytes: &[u8]) -> Binary<'a> {
    let mut bin = NewBinary::new(env, bytes.len());
    bin.as_mut_slice().copy_from_slice(bytes);
    bin.into()
}

#[rustler::nif]
fn typing_encode<'a>(env: Env<'a>, user_id: Binary) -> Binary<'a> {
    bytes_to_binary(env, &mercury_core::typing_encode(user_id.as_slice()))
}

#[rustler::nif]
fn typing_decode<'a>(env: Env<'a>, data: Binary) -> NifResult<Binary<'a>> {
    let uid = mercury_core::typing_decode(data.as_slice())
        .map_err(|e| rustler::Error::Term(Box::new(e.to_string())))?;
    Ok(bytes_to_binary(env, &uid))
}

#[rustler::nif]
fn read_receipt_encode<'a>(env: Env<'a>, user_id: Binary, message_id: Binary) -> Binary<'a> {
    bytes_to_binary(
        env,
        &mercury_core::read_receipt_encode(user_id.as_slice(), message_id.as_slice()),
    )
}

#[rustler::nif]
fn read_receipt_decode<'a>(
    env: Env<'a>,
    data: Binary,
) -> NifResult<(Binary<'a>, Binary<'a>)> {
    let rr = mercury_core::read_receipt_decode(data.as_slice())
        .map_err(|e| rustler::Error::Term(Box::new(e.to_string())))?;
    Ok((
        bytes_to_binary(env, &rr.user_id),
        bytes_to_binary(env, &rr.message_id),
    ))
}

#[rustler::nif]
fn mls_key_package_capnp_encode<'a>(env: Env<'a>, key_package: Binary) -> Binary<'a> {
    bytes_to_binary(
        env,
        &mercury_core::mls_key_package_encode(key_package.as_slice()),
    )
}

#[rustler::nif]
fn mls_key_package_capnp_decode<'a>(env: Env<'a>, data: Binary) -> NifResult<Binary<'a>> {
    let kp = mercury_core::mls_key_package_decode(data.as_slice())
        .map_err(|e| rustler::Error::Term(Box::new(e.to_string())))?;
    Ok(bytes_to_binary(env, &kp))
}

#[rustler::nif]
#[allow(clippy::needless_pass_by_value)]
fn mls_key_package_list_encode<'a>(env: Env<'a>, packages: Vec<Binary>) -> Binary<'a> {
    let slices: Vec<&[u8]> = packages.iter().map(Binary::as_slice).collect();
    bytes_to_binary(env, &mercury_core::mls_key_package_list_encode(&slices))
}

#[rustler::nif]
fn mls_key_package_list_decode<'a>(env: Env<'a>, data: Binary) -> NifResult<Vec<Binary<'a>>> {
    let pkgs = mercury_core::mls_key_package_list_decode(data.as_slice())
        .map_err(|e| rustler::Error::Term(Box::new(e.to_string())))?;
    Ok(pkgs.iter().map(|p| bytes_to_binary(env, p)).collect())
}

#[rustler::nif]
fn mls_commit_capnp_encode<'a>(env: Env<'a>, commit: Binary) -> Binary<'a> {
    bytes_to_binary(env, &mercury_core::mls_commit_encode(commit.as_slice()))
}

#[rustler::nif]
fn mls_commit_capnp_decode<'a>(env: Env<'a>, data: Binary) -> NifResult<Binary<'a>> {
    let c = mercury_core::mls_commit_decode(data.as_slice())
        .map_err(|e| rustler::Error::Term(Box::new(e.to_string())))?;
    Ok(bytes_to_binary(env, &c))
}

#[rustler::nif]
fn mls_welcome_capnp_encode<'a>(
    env: Env<'a>,
    welcome: Binary,
    user_id: Binary,
) -> Binary<'a> {
    bytes_to_binary(
        env,
        &mercury_core::mls_welcome_encode(welcome.as_slice(), user_id.as_slice()),
    )
}

#[rustler::nif]
fn mls_welcome_capnp_decode<'a>(
    env: Env<'a>,
    data: Binary,
) -> NifResult<(Binary<'a>, Binary<'a>)> {
    let w = mercury_core::mls_welcome_decode(data.as_slice())
        .map_err(|e| rustler::Error::Term(Box::new(e.to_string())))?;
    Ok((
        bytes_to_binary(env, &w.welcome),
        bytes_to_binary(env, &w.user_id),
    ))
}

rustler::init!("Elixir.MercuryCore.Native");
