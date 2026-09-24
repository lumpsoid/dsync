//! The rinf hub: the Rust core behind the Flutter head. Dart starts and
//! stops a one-transfer server with signals; Rust reports it back with
//! signals (signals.rs).

mod signals;

use std::path::PathBuf;
use std::sync::Arc;

use dsync_spike::identity::Identity;
use dsync_spike::peer_pin::PeerPin;
use dsync_spike::server::{Received, ServeEvent, ServeOptions, serve};
use dsync_spike::write_error::WriteError;
use dsync_spike::write_stats::Stage;
use rinf::{DartSignal, RustSignal, dart_shutdown, write_interface};
use signals::{
    ServeFailed, ServeReady, StageTiming, StartServe, StopServe, TransferDone, TransferProgress,
};
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
        writers: request.writers as usize,
    };
    let (events, forwarded) = mpsc::unbounded_channel();
    let forwarder = tokio::spawn(forward(forwarded));
    let served = serve(&identity, options, events).await;
    // Every progress signal goes out before the one that ends the transfer.
    let _ = forwarder.await;
    match served {
        Ok(Received {
            peer,
            metrics,
            writes,
        }) => TransferDone {
            peer_device_id: peer.to_string(),
            files: metrics.files,
            bytes: metrics.bytes,
            wall_seconds: metrics.wall.as_secs_f64(),
            mib_per_second: metrics.mib_per_second(),
            files_per_second: metrics.files_per_second(),
            cpu_seconds: metrics.cpu_seconds(),
            cpu_ms_per_mib: metrics.cpu_ms_per_mib(),
            writer_cpu_seconds: writes.writer_cpu.map(|c| c.as_secs_f64()),
            other_cpu_seconds: writes.other_cpu(metrics.cpu).map(|c| c.as_secs_f64()),
            writers: writes.writers as u32,
            writers_busy: writes.writers_busy(metrics.wall),
            queue_wait_mean_ms: writes
                .mean_queue_wait()
                .map_or(0.0, |d| d.as_secs_f64() * 1000.0),
            queue_wait_total_seconds: writes.queue_wait.as_secs_f64(),
            stages: Stage::ALL
                .into_iter()
                .filter_map(|stage| {
                    let time = writes.stage(stage);
                    time.mean().map(|mean| StageTiming {
                        name: stage.name().to_string(),
                        count: time.count,
                        mean_ms: mean.as_secs_f64() * 1000.0,
                        total_seconds: time.total.as_secs_f64(),
                    })
                })
                .collect(),
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
    let write = error.downcast_ref::<WriteError>();
    ServeFailed {
        message: format!("{error:#}"),
        path: write.map(|w| w.path.to_string()),
        stage: write.map(|w| w.stage.name().to_string()),
        io_kind: write.map(|w| format!("{:?}", w.kind())),
        os_code: write.and_then(WriteError::os_code),
    }
    .send_signal_to_dart();
}
