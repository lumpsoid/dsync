//! The rinf hub: the Rust core behind the Flutter head. Dart starts and
//! stops a one-transfer server with signals; Rust reports it back with
//! signals (signals.rs).

mod signals;

use std::path::PathBuf;
use std::sync::Arc;

use dsync_core::identity::Identity;
use dsync_core::peer_pin::PeerPin;
use dsync_core::server::{DEFAULT_WRITERS, Received, ServeEvent, ServeOptions, serve};
use rinf::{DartSignal, RustSignal, dart_shutdown, write_interface};
use signals::{ServeFailed, ServeReady, StartServe, StopServe, TransferDone, TransferProgress};
use tokio::sync::mpsc;
use tokio::task::JoinHandle;

write_interface!();

// Multithreaded: the socket, TLS and the writer pool's hand-offs run on
// worker threads, never on the thread that called into Rust.
#[tokio::main]
async fn main() {
    tokio::spawn(serve_on_request());
    dart_shutdown().await;
}

/// Runs one server at a time, as Dart asks. A new [StartServe] replaces the
/// running one; [StopServe] ends it.
async fn serve_on_request() {
    // One identity for the app's run: the spike keeps no key on disk
    // (where it belongs in the app is an open question, NOTES.md).
    let identity = match Identity::generate() {
        Ok(identity) => Arc::new(identity),
        Err(e) => return fail(e),
    };
    let starts = StartServe::get_dart_signal_receiver();
    let stops = StopServe::get_dart_signal_receiver();
    let mut running: Option<JoinHandle<()>> = None;
    loop {
        tokio::select! {
            Some(start) = starts.recv() => {
                if let Some(task) = running.take() {
                    task.abort();
                }
                running = Some(tokio::spawn(serve_once(identity.clone(), start.message)));
            }
            Some(_) = stops.recv() => {
                if let Some(task) = running.take() {
                    task.abort();
                }
            }
            else => break,
        }
    }
}

async fn serve_once(identity: Arc<Identity>, request: StartServe) {
    let allow: PeerPin = match request.allow_peer_id.parse() {
        Ok(pin) => pin,
        Err(e) => return fail(e),
    };
    let options = ServeOptions {
        root: PathBuf::from(request.root),
        port: request.port,
        allow,
        writers: DEFAULT_WRITERS,
    };
    let (events, forwarded) = mpsc::unbounded_channel();
    let forwarder = tokio::spawn(forward(forwarded));
    let served = serve(&identity, options, events).await;
    // Every progress signal goes out before the one that ends the transfer.
    let _ = forwarder.await;
    match served {
        Ok(Received { peer, metrics }) => TransferDone {
            peer_device_id: peer.to_string(),
            files: metrics.files,
            bytes: metrics.bytes,
            wall_seconds: metrics.wall.as_secs_f64(),
            mib_per_second: metrics.mib_per_second(),
            files_per_second: metrics.files_per_second(),
            cpu_seconds: metrics.cpu_seconds(),
            cpu_ms_per_mib: metrics.cpu_ms_per_mib(),
        }
        .send_signal_to_dart(),
        Err(e) => fail(e),
    }
}

/// Passes the core's events on to Dart.
async fn forward(mut events: mpsc::UnboundedReceiver<ServeEvent>) {
    while let Some(event) = events.recv().await {
        match event {
            ServeEvent::Ready { port, device_id } => ServeReady {
                port,
                device_id: device_id.to_string(),
            }
            .send_signal_to_dart(),
            ServeEvent::Connected { .. } => {}
            ServeEvent::Progress { files, bytes } => {
                TransferProgress { files, bytes }.send_signal_to_dart()
            }
            // Per-file completion stays in Rust: Dart sees it as the
            // throttled count.
            ServeEvent::FileDone { .. } => {}
        }
    }
}

fn fail(error: anyhow::Error) {
    ServeFailed {
        message: format!("{error:#}"),
    }
    .send_signal_to_dart();
}
