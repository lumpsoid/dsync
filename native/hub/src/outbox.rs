//! Where the hub's stream signals go. The rinf shell drains it into
//! `send_signal_to_dart`; a test holds the receiving end and reads what
//! the head would have seen.

use tokio::sync::mpsc;

use crate::signals::{PairingSnapshot, RunSnapshot, ServeSnapshot};
use crate::views::{PairingView, RunView, ServeView};

/// One stream signal, in the order it was emitted.
pub enum Outgoing {
    /// Boxed: a run's view is far larger than the other signals.
    Run(Box<RunSnapshot>),
    Serve(ServeSnapshot),
    Pairing(PairingSnapshot),
}

/// The sending end. Unbounded: every producer is either throttled (a
/// run's and serving's snapshots) or rare (pairing), and a send never
/// waits on Dart.
#[derive(Clone)]
pub struct Outbox(mpsc::UnboundedSender<Outgoing>);

impl Outbox {
    pub fn channel() -> (Outbox, mpsc::UnboundedReceiver<Outgoing>) {
        let (sender, receiver) = mpsc::unbounded_channel();
        (Outbox(sender), receiver)
    }

    /// Dropped when nobody listens any more (the shell shut down).
    fn send(&self, outgoing: Outgoing) {
        let _ = self.0.send(outgoing);
    }

    /// `last`: the session sends nothing after this one.
    pub fn run(&self, session: u64, view: RunView, last: bool) {
        self.send(Outgoing::Run(Box::new(RunSnapshot {
            session,
            view,
            last,
        })));
    }

    pub fn serve(&self, session: u64, view: ServeView, last: bool) {
        self.send(Outgoing::Serve(ServeSnapshot {
            session,
            view,
            last,
        }));
    }

    pub fn pairing(&self, session: u64, view: PairingView, last: bool) {
        self.send(Outgoing::Pairing(PairingSnapshot {
            session,
            view,
            last,
        }));
    }
}
