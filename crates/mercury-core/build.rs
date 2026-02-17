fn main() {
    capnpc::CompilerCommand::new()
        .src_prefix("../../schema")
        .file("../../schema/mercury/v1/envelope.capnp")
        .file("../../schema/mercury/v1/message.capnp")
        .file("../../schema/mercury/v1/channel.capnp")
        .file("../../schema/mercury/v1/user.capnp")
        .file("../../schema/mercury/v1/sync.capnp")
        .file("../../schema/mercury/v1/event.capnp")
        .run()
        .expect("capnp compile failed");
}
