use criterion::{Criterion, black_box, criterion_group, criterion_main};
use mercury_core::{MessageId, TimeBucket};

fn bench_message_id_generation(c: &mut Criterion) {
    c.bench_function("MessageId::new", |b| {
        b.iter(|| black_box(MessageId::new()));
    });
}

fn bench_time_bucket(c: &mut Criterion) {
    let ts = 1_700_000_000_000_u64;
    c.bench_function("TimeBucket::from_timestamp_ms", |b| {
        b.iter(|| black_box(TimeBucket::from_timestamp_ms(black_box(ts))));
    });
}

criterion_group!(benches, bench_message_id_generation, bench_time_bucket);
criterion_main!(benches);
