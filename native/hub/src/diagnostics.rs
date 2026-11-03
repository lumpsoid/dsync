//! The diagnostics log ([`DiagnosticsLog`]) from the head's side: a panic
//! anywhere in the hub lands in it, the head notes its own errors in it,
//! and reads it back whole, under the app's version and platform, for the
//! user to attach to a bug report.
//!
//! A release build has no other record of a panic: rinf prints one only
//! under `debug_assertions`, and Android drops a release build's stderr.

use std::env::consts::{ARCH, OS};
use std::panic::{self, PanicHookInfo};
use std::sync::{Mutex, PoisonError};
use std::thread;

use dsync_core::DiagnosticsLog;

use crate::dispatch::{Handled, Hub, blocking, text};
use crate::signals::ReplyResult;

/// The log a panic is noted in: the latest `Init`'s, none before it. A
/// process-wide hook can only reach it through a static.
static PANICS_TO: Mutex<Option<DiagnosticsLog>> = Mutex::new(None);

/// This build, as the log's reader needs it.
fn build() -> String {
    format!("dsync {} on {OS} {ARCH}", env!("CARGO_PKG_VERSION"))
}

/// Notes every panic from here on in the log [`log_panics_to`] names,
/// then hands it to the hook that was there, so a debug build still
/// prints it.
pub fn log_panics() {
    let previous = panic::take_hook();
    panic::set_hook(Box::new(move |info| {
        note_panic(info);
        previous(info);
    }));
}

/// Points the panic hook at `log`, and notes that the core started there.
/// A line that cannot be written is not a reason `Init` fails.
pub(crate) async fn log_panics_to(log: DiagnosticsLog) {
    *PANICS_TO.lock().unwrap_or_else(PoisonError::into_inner) = Some(log.clone());
    let _unlogged = blocking(move || {
        log.note(&format!("core started: {}", build()))
            .map_err(text)
    })
    .await;
}

fn note_panic(info: &PanicHookInfo<'_>) {
    // `try_lock`: a panic while the log is being pointed elsewhere is
    // missed rather than deadlocking the thread that panicked.
    let Ok(guard) = PANICS_TO.try_lock() else {
        return;
    };
    if let Some(log) = guard.as_ref() {
        let thread = thread::current();
        let name = thread.name().unwrap_or("unnamed");
        let _unlogged = log.note(&format!("rust panic on thread {name}: {info}"));
    }
}

impl Hub {
    /// Notes `message`, one of the head's own errors.
    pub(crate) async fn note_diagnostic(&self, message: String) -> Handled {
        let log = DiagnosticsLog::new(&self.state);
        blocking(move || {
            log.note(&message).map_err(text)?;
            Ok(ReplyResult::Done)
        })
        .await
    }

    /// The log whole, under the build it came from.
    pub(crate) async fn read_diagnostics(&self) -> Handled {
        let log = DiagnosticsLog::new(&self.state);
        blocking(move || {
            let kept = log.read().map_err(text)?;
            let text = if kept.is_empty() {
                format!("{}\n\nNothing logged yet.\n", build())
            } else {
                format!("{}\n\n{kept}", build())
            };
            Ok(ReplyResult::Diagnostics { text })
        })
        .await
    }
}
