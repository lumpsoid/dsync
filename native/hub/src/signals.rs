//! The signals between the Flutter head and the Rust core. `rinf gen`
//! turns these into Dart classes under lib/app/rust/bindings.

use rinf::{DartSignal, RustSignal, SignalPiece};
use serde::{Deserialize, Serialize};

/// Dart asks Rust to receive one tree into [root] on [port], from the peer
/// whose device id is [allow_peer_id] (or `ANY`), with [writers] blocking
/// file-writer threads (at least one).
#[derive(Deserialize, DartSignal)]
pub struct StartServe {
    pub root: String,
    pub port: u16,
    pub allow_peer_id: String,
    pub writers: u32,
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
    /// The writer threads' CPU (per-thread clock), and the rest of the
    /// process's: None where either reading is missing.
    pub writer_cpu_seconds: Option<f64>,
    pub other_cpu_seconds: Option<f64>,
    pub writers: u32,
    /// The mean number of writers busy with a file over the wall time.
    pub writers_busy: f64,
    /// From a file's header arriving to a writer taking it.
    pub queue_wait_mean_ms: f64,
    pub queue_wait_total_seconds: f64,
    /// Every stage of writing a file that ran at least once, in order.
    pub stages: Vec<StageTiming>,
}

/// One stage of writing a file (mkdir, probe, create, open, wait, write,
/// mtime, close, rename), over the whole transfer.
#[derive(Serialize, SignalPiece)]
pub struct StageTiming {
    pub name: String,
    pub count: u64,
    pub mean_ms: f64,
    pub total_seconds: f64,
}

/// Serving ended without a finished transfer: bind, handshake, I/O, or a
/// refused peer. A [StopServe] ends it without this. When a writer failed,
/// the last four say on which file, at which stage, and the io error's kind
/// and OS code.
#[derive(Serialize, RustSignal)]
pub struct ServeFailed {
    pub message: String,
    pub path: Option<String>,
    pub stage: Option<String>,
    pub io_kind: Option<String>,
    pub os_code: Option<i32>,
}
