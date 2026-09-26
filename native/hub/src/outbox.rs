//! Where the hub's stream signals go. The rinf shell drains it into
//! `send_signal_to_dart`; a test holds the receiving end and reads what
//! the head would have seen.

use tokio::sync::mpsc;

use crate::signals::{EnrolmentUpdate, EnrolmentUpdateBody, RunSnapshot, ServeSnapshot};
use crate::views::{RunView, ServeView};

/// One stream signal, in the order it was emitted.
pub enum Outgoing {
    /// Boxed: a run's view is far larger than the other signals.
    Run(Box<RunSnapshot>),
    Serve(ServeSnapshot),
    Enrolment(EnrolmentUpdate),
}

/// The sending end. Unbounded: every producer is either throttled (a
/// run's snapshots) or rare (serving and pairing), and a send never waits
/// on Dart.
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

    pub fn run(&self, session: u64, view: RunView) {
        self.send(Outgoing::Run(Box::new(RunSnapshot { session, view })));
    }

    pub fn serve(&self, session: u64, view: ServeView) {
        self.send(Outgoing::Serve(ServeSnapshot { session, view }));
    }

    pub fn enrolment(&self, session: u64, update: EnrolmentUpdateBody) {
        self.send(Outgoing::Enrolment(EnrolmentUpdate { session, update }));
    }
}
