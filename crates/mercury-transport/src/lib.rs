#![doc = "Mercury transport: QUIC/WebTransport server."]

#[must_use]
pub fn hello() -> &'static str {
    "mercury-transport"
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn it_works() {
        assert_eq!(hello(), "mercury-transport");
    }
}
