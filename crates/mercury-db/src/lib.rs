#![doc = "Mercury database clients: `ScyllaDB` + `PostgreSQL`."]

#[must_use]
pub fn hello() -> &'static str {
    "mercury-db"
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn it_works() {
        assert_eq!(hello(), "mercury-db");
    }
}
