//! The rinf hub: the Flutter head's way into `dsync-core` (plan D10).
//!
//! Thin by rule: decode a signal, call a core flow, encode what it
//! returned - no business `if` here; every verdict is the core's or the
//! domain's. The rinf plumbing is this file alone: it reads the host's
//! facts once, hands each [`signals::CoreRequest`] to [`Core::handle`] and
//! sends its [`signals::CoreReply`], and drains the [`Outbox`] of stream
//! signals into Dart. Everything below it is plain async Rust, driven the
//! same way by the tests (tests/).
//!
//! Signals are bincode, rinf's fixed choice (plan OQ5); the replica wire
//! protocol stays postcard.

mod archives;
mod devices;
mod diagnostics;
mod dispatch;
mod outbox;
mod pairing;
mod profiles;
mod run;
mod serve;
mod sessions;
pub mod signals;
pub mod views;

use std::env;
use std::sync::Arc;

use dsync_domain::{HostFacts, Platform};
use rinf::{DartSignal, RustSignal, dart_shutdown, write_interface};

pub use dispatch::Core;
pub use outbox::{Outbox, Outgoing};
pub use run::REFRESH_INTERVAL;
use signals::CoreRequest;

write_interface!();

// Multithreaded: sockets, TLS, scans and the writer pool's hand-offs run
// on worker threads, never on the thread that called into Rust. The core
// itself never creates a runtime.
#[tokio::main]
async fn main() {
    let (out, mut outgoing) = Outbox::channel();
    let core = Arc::new(Core::new(host_facts(), out));
    tokio::spawn(async move {
        while let Some(signal) = outgoing.recv().await {
            match signal {
                Outgoing::Run(snapshot) => (*snapshot).send_signal_to_dart(),
                Outgoing::Serve(snapshot) => snapshot.send_signal_to_dart(),
                Outgoing::Pairing(snapshot) => snapshot.send_signal_to_dart(),
            }
        }
    });
    tokio::spawn(async move {
        let requests = CoreRequest::get_dart_signal_receiver();
        while let Some(pack) = requests.recv().await {
            let core = core.clone();
            tokio::spawn(async move {
                let CoreRequest { id, command } = pack.message;
                core.handle(id, command).await.send_signal_to_dart();
            });
        }
    });
    dart_shutdown().await;
}

/// This process's environment and working directory, read once. An
/// unreadable working directory resolves nothing relative: the head only
/// ever hands in absolute paths.
fn host_facts() -> HostFacts {
    let vars: Vec<(String, String)> = env::vars_os()
        .filter_map(|(name, value)| Some((name.into_string().ok()?, value.into_string().ok()?)))
        .collect();
    let home = vars
        .iter()
        .find(|(name, _)| name == "HOME")
        .map(|(_, value)| value.clone());
    let cwd = env::current_dir()
        .map(|dir| dir.to_string_lossy().into_owned())
        .unwrap_or_default();
    HostFacts::new(Platform::HOST, home, vars, cwd)
}
