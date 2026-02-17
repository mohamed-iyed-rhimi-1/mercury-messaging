//! Cap'n Proto encode/decode helpers for the wire format.
//! Generated schema modules are re-exported at crate root (required by capnpc codegen).

#![allow(clippy::missing_panics_doc, clippy::missing_errors_doc, clippy::must_use_candidate)]

use capnp::message::{Builder, ReaderOptions};
use capnp::serialize;

use crate::envelope_capnp::envelope;
use crate::event_capnp::{
    mls_commit, mls_key_package, mls_key_package_list, mls_welcome, read_receipt, typing_event,
};

/// Decoded envelope fields.
pub struct DecodedEnvelope {
    pub tenant_id: Vec<u8>,
    pub channel_id: Vec<u8>,
    pub sender_id: Vec<u8>,
    pub message_id: Vec<u8>,
    pub timestamp: u64,
    pub payload: Vec<u8>,
}

/// Serialize an Envelope to Cap'n Proto bytes.
pub fn envelope_encode(
    tenant_id: &[u8],
    channel_id: &[u8],
    sender_id: &[u8],
    message_id: &[u8],
    timestamp: u64,
    payload: &[u8],
) -> Vec<u8> {
    let mut builder = Builder::new_default();
    {
        let mut env = builder.init_root::<envelope::Builder<'_>>();
        env.set_tenant_id(tenant_id);
        env.set_channel_id(channel_id);
        env.set_sender_id(sender_id);
        env.set_message_id(message_id);
        env.set_timestamp(timestamp);
        env.set_payload(payload);
    }
    let mut out = Vec::new();
    serialize::write_message(&mut out, &builder).expect("capnp serialize");
    out
}

/// Deserialize Cap'n Proto bytes into envelope fields.
pub fn envelope_decode(bytes: &[u8]) -> Result<DecodedEnvelope, capnp::Error> {
    let reader = serialize::read_message(bytes, ReaderOptions::default())?;
    let env = reader.get_root::<envelope::Reader<'_>>()?;

    Ok(DecodedEnvelope {
        tenant_id: env.get_tenant_id()?.to_vec(),
        channel_id: env.get_channel_id()?.to_vec(),
        sender_id: env.get_sender_id()?.to_vec(),
        message_id: env.get_message_id()?.to_vec(),
        timestamp: env.get_timestamp(),
        payload: env.get_payload()?.to_vec(),
    })
}

// ── Event encode/decode helpers ──

pub fn typing_encode(user_id: &[u8]) -> Vec<u8> {
    let mut b = Builder::new_default();
    b.init_root::<typing_event::Builder<'_>>()
        .set_user_id(user_id);
    let mut out = Vec::new();
    serialize::write_message(&mut out, &b).expect("capnp serialize");
    out
}

pub fn typing_decode(bytes: &[u8]) -> Result<Vec<u8>, capnp::Error> {
    let r = serialize::read_message(bytes, ReaderOptions::default())?;
    Ok(r.get_root::<typing_event::Reader<'_>>()?
        .get_user_id()?
        .to_vec())
}

pub fn read_receipt_encode(user_id: &[u8], message_id: &[u8]) -> Vec<u8> {
    let mut b = Builder::new_default();
    {
        let mut rr = b.init_root::<read_receipt::Builder<'_>>();
        rr.set_user_id(user_id);
        rr.set_message_id(message_id);
    }
    let mut out = Vec::new();
    serialize::write_message(&mut out, &b).expect("capnp serialize");
    out
}

pub struct DecodedReadReceipt {
    pub user_id: Vec<u8>,
    pub message_id: Vec<u8>,
}

pub fn read_receipt_decode(bytes: &[u8]) -> Result<DecodedReadReceipt, capnp::Error> {
    let r = serialize::read_message(bytes, ReaderOptions::default())?;
    let rr = r.get_root::<read_receipt::Reader<'_>>()?;
    Ok(DecodedReadReceipt {
        user_id: rr.get_user_id()?.to_vec(),
        message_id: rr.get_message_id()?.to_vec(),
    })
}

pub fn mls_key_package_encode(key_package: &[u8]) -> Vec<u8> {
    let mut b = Builder::new_default();
    b.init_root::<mls_key_package::Builder<'_>>()
        .set_key_package(key_package);
    let mut out = Vec::new();
    serialize::write_message(&mut out, &b).expect("capnp serialize");
    out
}

pub fn mls_key_package_decode(bytes: &[u8]) -> Result<Vec<u8>, capnp::Error> {
    let r = serialize::read_message(bytes, ReaderOptions::default())?;
    Ok(r.get_root::<mls_key_package::Reader<'_>>()?
        .get_key_package()?
        .to_vec())
}

pub fn mls_key_package_list_encode(packages: &[&[u8]]) -> Vec<u8> {
    assert!(packages.len() <= 10_000, "too many key packages");
    let mut b = Builder::new_default();
    {
        let root = b.init_root::<mls_key_package_list::Builder<'_>>();
        let len = u32::try_from(packages.len()).expect("list len fits u32");
        let mut list = root.init_key_packages(len);
        for (i, pkg) in packages.iter().enumerate() {
            list.set(u32::try_from(i).expect("index fits u32"), pkg);
        }
    }
    let mut out = Vec::new();
    serialize::write_message(&mut out, &b).expect("capnp serialize");
    out
}

pub fn mls_key_package_list_decode(bytes: &[u8]) -> Result<Vec<Vec<u8>>, capnp::Error> {
    let r = serialize::read_message(bytes, ReaderOptions::default())?;
    let list = r
        .get_root::<mls_key_package_list::Reader<'_>>()?
        .get_key_packages()?;
    let mut out = Vec::with_capacity(list.len() as usize);
    for i in 0..list.len() {
        out.push(list.get(i)?.to_vec());
    }
    Ok(out)
}

pub fn mls_commit_encode(commit: &[u8]) -> Vec<u8> {
    let mut b = Builder::new_default();
    b.init_root::<mls_commit::Builder<'_>>()
        .set_commit(commit);
    let mut out = Vec::new();
    serialize::write_message(&mut out, &b).expect("capnp serialize");
    out
}

pub fn mls_commit_decode(bytes: &[u8]) -> Result<Vec<u8>, capnp::Error> {
    let r = serialize::read_message(bytes, ReaderOptions::default())?;
    Ok(r.get_root::<mls_commit::Reader<'_>>()?
        .get_commit()?
        .to_vec())
}

pub struct DecodedMlsWelcome {
    pub welcome: Vec<u8>,
    pub user_id: Vec<u8>,
}

pub fn mls_welcome_encode(welcome: &[u8], user_id: &[u8]) -> Vec<u8> {
    let mut b = Builder::new_default();
    {
        let mut w = b.init_root::<mls_welcome::Builder<'_>>();
        w.set_welcome(welcome);
        w.set_user_id(user_id);
    }
    let mut out = Vec::new();
    serialize::write_message(&mut out, &b).expect("capnp serialize");
    out
}

pub fn mls_welcome_decode(bytes: &[u8]) -> Result<DecodedMlsWelcome, capnp::Error> {
    let r = serialize::read_message(bytes, ReaderOptions::default())?;
    let w = r.get_root::<mls_welcome::Reader<'_>>()?;
    Ok(DecodedMlsWelcome {
        welcome: w.get_welcome()?.to_vec(),
        user_id: w.get_user_id()?.to_vec(),
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn roundtrip_envelope() {
        let tid = [1u8; 16];
        let cid = [2u8; 16];
        let sid = [3u8; 16];
        let mid = [4u8; 16];
        let ts = 1_700_000_000_000u64;
        let payload = b"hello capnp";

        let encoded = envelope_encode(&tid, &cid, &sid, &mid, ts, payload);
        let decoded = envelope_decode(&encoded).unwrap();

        assert_eq!(decoded.tenant_id, tid);
        assert_eq!(decoded.channel_id, cid);
        assert_eq!(decoded.sender_id, sid);
        assert_eq!(decoded.message_id, mid);
        assert_eq!(decoded.timestamp, ts);
        assert_eq!(decoded.payload, payload);
    }

    #[test]
    fn envelope_is_compact() {
        let encoded = envelope_encode(&[0; 16], &[0; 16], &[0; 16], &[0; 16], 0, b"hi");
        assert!(encoded.len() < 200, "encoded size: {}", encoded.len());
    }

    #[test]
    fn roundtrip_typing() {
        let uid = [7u8; 16];
        let encoded = typing_encode(&uid);
        let decoded = typing_decode(&encoded).unwrap();
        assert_eq!(decoded, uid);
    }

    #[test]
    fn roundtrip_read_receipt() {
        let uid = [8u8; 16];
        let mid = [9u8; 16];
        let encoded = read_receipt_encode(&uid, &mid);
        let decoded = read_receipt_decode(&encoded).unwrap();
        assert_eq!(decoded.user_id, uid);
        assert_eq!(decoded.message_id, mid);
    }

    #[test]
    fn roundtrip_mls_key_package() {
        let kp = vec![42u8; 256];
        let encoded = mls_key_package_encode(&kp);
        let decoded = mls_key_package_decode(&encoded).unwrap();
        assert_eq!(decoded, kp);
    }

    #[test]
    fn roundtrip_mls_key_package_list() {
        let pkgs: Vec<Vec<u8>> = vec![vec![1u8; 64], vec![2u8; 128]];
        let refs: Vec<&[u8]> = pkgs.iter().map(|p| p.as_slice()).collect();
        let encoded = mls_key_package_list_encode(&refs);
        let decoded = mls_key_package_list_decode(&encoded).unwrap();
        assert_eq!(decoded, pkgs);
    }

    #[test]
    fn roundtrip_mls_commit() {
        let commit = vec![55u8; 100];
        let encoded = mls_commit_encode(&commit);
        let decoded = mls_commit_decode(&encoded).unwrap();
        assert_eq!(decoded, commit);
    }

    #[test]
    fn roundtrip_mls_welcome() {
        let welcome = vec![66u8; 200];
        let uid = [77u8; 16];
        let encoded = mls_welcome_encode(&welcome, &uid);
        let decoded = mls_welcome_decode(&encoded).unwrap();
        assert_eq!(decoded.welcome, welcome);
        assert_eq!(decoded.user_id, uid);
    }
}
