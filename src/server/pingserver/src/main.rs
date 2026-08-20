#[macro_use]
extern crate logger;

use config::PingserverConfig;
use entrystore::Noop;
use logger::configure_logging;
use protocol_ping::{PingProtocol, Request, Response};
use server::{ProcessBuilder, PERCENTILES};

common::pelikan_main! {
    about: "A minimal ping/pong server built with Pelikan libraries. \
        Useful for testing and benchmarking the framework with \
        near-zero application overhead.",
    config: PingserverConfig,
    percentiles: PERCENTILES,
    launch: |config: PingserverConfig| {
        let log = configure_logging(&config);
        common::metrics::init();
        let storage = Noop::new();
        let protocol = PingProtocol::default();
        ProcessBuilder::<PingProtocol, Request, Response, Noop>::new(
            &config, log, protocol, storage,
        )
        .expect("failed to initialize process")
        .spawn()
        .wait()
    },
}
