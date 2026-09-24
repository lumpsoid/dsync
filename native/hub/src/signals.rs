//! The signals between the Flutter head and the Rust core. `rinf gen`
//! turns these into Dart classes under lib/app/rust/bindings.

use rinf::{DartSignal, RustSignal};
use serde::{Deserialize, Serialize};

/// Dart asks Rust to receive one tree into [root] on [port], from the peer
/// whose device id is [allow_peer_id] (or `ANY`).
#[derive(Deserialize, DartSignal)]
pub struct StartServe {
    pub root: String,
    pub port: u16,
    pub allow_peer_id: String,
}

/// Dart asks Rust to stop serving, mid-transfer or before one starts.
#[derive(Deserialize, DartSignal)]
pub struct StopServe;

/// Rust is listening; [device_id] is the id a pushing peer pins.
#[derive(Serialize, RustSignal)]
pub struct ServeReady {
    pub port: u16,
    pub device_id: String,
}

/// Files and bytes on disk so far; at most one per 50 ms.
#[derive(Serialize, RustSignal)]
pub struct TransferProgress {
    pub files: u64,
    pub bytes: u64,
}

/// The transfer is over and every file is on disk. The metrics cover the
/// span from the end of the handshake to the last file on disk.
#[derive(Serialize, RustSignal)]
pub struct TransferDone {
    pub peer_device_id: String,
    pub files: u64,
    pub bytes: u64,
    pub wall_seconds: f64,
    pub mib_per_second: f64,
    pub files_per_second: f64,
    /// None where the platform has no /proc/self/stat.
    pub cpu_seconds: Option<f64>,
    pub cpu_ms_per_mib: Option<f64>,
}

/// Serving ended without a finished transfer: bind, handshake, I/O, or a
/// refused peer. A [StopServe] ends it without this.
#[derive(Serialize, RustSignal)]
pub struct ServeFailed {
    pub message: String,
}
