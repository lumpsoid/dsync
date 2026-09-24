//! dsync's Rust core (task 07876c spike): a one-way tree transfer over
//! mutually authenticated TLS 1.3 (rustls on ring), each side pinned by the
//! other's device id.

pub mod client;
pub mod cpu;
pub mod device_id;
pub mod identity;
pub mod metrics;
pub mod peer_pin;
pub mod rel_path;
pub mod server;
pub mod throttle;
pub mod tls;
pub mod wire;

/// Read and write size for file and socket I/O on both sides.
pub const IO_CHUNK: usize = 256 << 10;
