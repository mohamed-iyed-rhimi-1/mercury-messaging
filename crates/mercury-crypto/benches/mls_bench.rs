use criterion::{Criterion, black_box, criterion_group, criterion_main};
use mercury_crypto::mls::MlsGroupManager;

fn bench_mls(c: &mut Criterion) {
    c.bench_function("mls_generate_key_package", |b| {
        let mgr = MlsGroupManager::new(b"kp-bench").unwrap();
        b.iter(|| mgr.generate_key_package().unwrap());
    });

    c.bench_function("mls_create_group", |b| {
        b.iter_with_setup(
            || MlsGroupManager::new(b"cg-bench").unwrap(),
            |mut mgr| mgr.create_group(black_box(b"g")).unwrap(),
        );
    });

    c.bench_function("mls_add_member", |b| {
        b.iter_with_setup(
            || {
                let mut alice = MlsGroupManager::new(b"add-bench").unwrap();
                let bob = MlsGroupManager::new(b"add-bob").unwrap();
                let kp = bob.generate_key_package().unwrap();
                alice.create_group(b"add-group").unwrap();
                (alice, kp)
            },
            |(mut alice, kp)| {
                alice
                    .add_member(black_box(b"add-group"), black_box(&kp))
                    .unwrap()
            },
        );
    });

    // Setup shared group for encrypt/decrypt
    let mut alice = MlsGroupManager::new(b"alice-bench").unwrap();
    let mut bob = MlsGroupManager::new(b"bob-bench").unwrap();
    let bob_kp = bob.generate_key_package().unwrap();
    alice.create_group(b"bench-group").unwrap();
    let (_commit, welcome) = alice.add_member(b"bench-group", &bob_kp).unwrap();
    let bob_gid = bob.process_welcome(&welcome).unwrap();
    let plaintext = b"hello world benchmark msg";

    c.bench_function("mls_encrypt", |b| {
        b.iter(|| {
            alice
                .encrypt(black_box(b"bench-group"), black_box(plaintext))
                .unwrap()
        });
    });

    c.bench_function("mls_encrypt_decrypt", |b| {
        b.iter(|| {
            let ct = alice.encrypt(b"bench-group", black_box(plaintext)).unwrap();
            bob.decrypt(&bob_gid, black_box(&ct)).unwrap()
        });
    });
}

criterion_group!(benches, bench_mls);
criterion_main!(benches);
