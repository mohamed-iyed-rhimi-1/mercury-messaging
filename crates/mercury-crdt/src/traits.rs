/// All CRDTs implement this trait.
/// Laws (verified by property tests):
///   1. Commutative: merge(a, b) == merge(b, a)
///   2. Associative: merge(merge(a, b), c) == merge(a, merge(b, c))
///   3. Idempotent:  merge(a, a) == a
pub trait Mergeable {
    fn merge(&mut self, other: &Self);
}
