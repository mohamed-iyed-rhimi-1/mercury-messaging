use criterion::{Criterion, black_box, criterion_group, criterion_main};
use mercury_crdt::{GCounter, Hlc, Mergeable, MessageLog, ORSet};

fn node(id: u8) -> [u8; 16] {
    let mut n = [0u8; 16];
    n[0] = id;
    n
}

fn bench_hlc_tick(c: &mut Criterion) {
    let mut hlc = Hlc::now(node(1));
    c.bench_function("Hlc::tick", |b| {
        b.iter(|| {
            hlc.tick();
            black_box(&hlc);
        });
    });
}

fn bench_hlc_merge(c: &mut Criterion) {
    let mut local = Hlc::now(node(1));
    let remote = Hlc::now(node(2));
    c.bench_function("Hlc::merge", |b| {
        b.iter(|| {
            local.merge(black_box(&remote));
        });
    });
}

fn bench_message_log_append_1000(c: &mut Criterion) {
    c.bench_function("MessageLog::append x1000", |b| {
        b.iter(|| {
            let mut log = MessageLog::new();
            for i in 0..1000u64 {
                let hlc = Hlc {
                    wall_clock_ms: i,
                    counter: 0,
                    node_id: node(1),
                };
                log.append(hlc, vec![0u8; 64]).unwrap();
            }
            black_box(&log);
        });
    });
}

fn bench_orset_merge_1000(c: &mut Criterion) {
    let mut a = ORSet::new();
    let mut b = ORSet::new();
    for i in 0u32..500 {
        a.add(i, node(1));
        b.add(i + 500, node(2));
    }
    c.bench_function("ORSet::merge (1000 elements)", |b_iter| {
        b_iter.iter(|| {
            let mut clone = a.clone();
            clone.merge(black_box(&b));
            black_box(&clone);
        });
    });
}

fn bench_gcounter_merge(c: &mut Criterion) {
    let mut a = GCounter::new();
    let mut b = GCounter::new();
    for i in 0u8..100 {
        a.increment(node(i));
        b.increment(node(i));
    }
    c.bench_function("GCounter::merge (100 nodes)", |bench| {
        bench.iter(|| {
            let mut clone = a.clone();
            clone.merge(black_box(&b));
            black_box(&clone);
        });
    });
}

criterion_group!(
    benches,
    bench_hlc_tick,
    bench_hlc_merge,
    bench_message_log_append_1000,
    bench_orset_merge_1000,
    bench_gcounter_merge,
);
criterion_main!(benches);
