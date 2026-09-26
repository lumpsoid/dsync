//! Serving paired devices (SPEC §4.4) from the head: the CLI's `agent
//! --serve` wiring, each connection's story kept in the session's
//! [`ServeState`] and sent whole as `session`'s snapshots until the head
//! stops it.

use std::collections::VecDeque;
use std::future::Future;
use std::sync::{Arc, Mutex, PoisonError};
use std::time::SystemTime;

use dsync_core::{
    LocalReplica, PeerEvent, PeerListener, ReplicaError, StateDir, bind_peer, interface_addresses,
};
use dsync_domain::host_port::{format_host_port, parse_bind_address};
use dsync_domain::{ReplicaSpec, Tuning, advertised_host, preferred_advertisable_address};
use tokio::task::AbortHandle;

use crate::dispatch::{Handled, Hub, text};
use crate::outbox::Outbox;
use crate::sessions::Session;
use crate::signals::ReplyResult;
use crate::views::{
    AddressesView, ServeEventView, ServeLineView, ServePhaseView, ServeStartedView, ServeView,
    millis,
};

/// How many connection events a serving session keeps: enough to see a
/// handful of refusals in a row while diagnosing a first sync, few enough
/// that a port being scanned costs a fixed amount.
pub const SERVE_LINES: usize = 20;

impl Hub {
    /// Binds `bind:port` and serves until [`Hub::stop_serve`]. A bind
    /// that fails is the reply; nothing is left running.
    pub(crate) async fn start_serve(&self, session: u64, bind: &str, port: u16) -> Handled {
        let bind = parse_bind_address(bind).map_err(text)?;
        let identity = self
            .identities()
            .load_or_create(&self.device_name, SystemTime::now())
            .map_err(text)?;
        let device_id = identity.device_id().to_string();
        let listener = bind_peer(bind, port).await.map_err(text)?;
        let bound = listener.local_addr().map_err(text)?;
        // An unreadable interface list is only a worse guess.
        let interfaces = interface_addresses().unwrap_or_default();
        let advertised = format_host_port(&advertised_host(None, bind, &interfaces), bound.port());
        let control = Arc::new(ServeControl {
            session,
            out: self.out.clone(),
            state: Mutex::new(ServeState::new(advertised.clone())),
        });
        control.update(|_| {});
        let opener = Opener {
            state: self.state.clone(),
            home: self.facts.home().map(str::to_owned),
            tuning: self.tuning,
            control: control.clone(),
        };
        let peers = Arc::new(PeerListener::new(
            move |spec| opener.open(spec),
            identity,
            self.paired(),
            &self.facts,
            self.tuning,
        ));
        let serving = control.clone();
        self.sessions.spawn(
            session,
            |task| Session::Serve(Serving { task, control }),
            async move {
                let events = serving.clone();
                let ended = peers
                    .serve(listener, move |event| {
                        events.update(|state| state.record(now_ms(), line(event)));
                    })
                    .await;
                serving.update(|state| state.ended(ended.err().map(text)));
            },
        );
        Ok(ReplyResult::ServeStarted(ServeStartedView {
            port: bound.port(),
            advertised,
            device_id,
        }))
    }

    pub(crate) fn stop_serve(&self, session: u64) -> Handled {
        match self
            .sessions
            .take_if(session, |live| matches!(live, Session::Serve(_)))
        {
            Some(Session::Serve(Serving { task, control })) => {
                task.abort();
                control.update(|state| state.ended(None));
                Ok(ReplyResult::Done)
            }
            _ => Err(format!("nothing is serving in session {session}")),
        }
    }

    /// This machine's addresses, and the one a peer is best told to dial.
    pub(crate) fn serve_addresses(&self) -> ReplyResult {
        let interfaces = interface_addresses().unwrap_or_default();
        ReplyResult::Addresses(AddressesView {
            interfaces: interfaces.iter().map(ToString::to_string).collect(),
            preferred: preferred_advertisable_address(&interfaces)
                .map(|address| address.to_string()),
        })
    }
}

/// A live serving session's handles.
pub(crate) struct Serving {
    pub task: AbortHandle,
    pub control: Arc<ServeControl>,
}

/// A serving session's state and where its snapshots go.
pub(crate) struct ServeControl {
    session: u64,
    out: Outbox,
    state: Mutex<ServeState>,
}

impl ServeControl {
    /// Applies `change` and sends the session as it now stands: serving
    /// changes rarely, so every change goes out at once.
    fn update(&self, change: impl FnOnce(&mut ServeState)) {
        let mut state = self.state.lock().unwrap_or_else(PoisonError::into_inner);
        change(&mut state);
        self.out.serve(self.session, state.view(), state.is_over());
    }
}

fn now_ms() -> i64 {
    millis(SystemTime::now())
}

#[derive(Clone, PartialEq, Eq, Debug)]
enum Phase {
    Listening(String),
    Stopped,
    Failed(String),
}

/// A serving session as the head sees it: whether it answers, and the
/// last [`SERVE_LINES`] connection events, newest first.
pub(crate) struct ServeState {
    phase: Phase,
    lines: VecDeque<ServeLineView>,
}

impl ServeState {
    /// Answering at `advertised`, nothing reported yet.
    fn new(advertised: String) -> ServeState {
        ServeState {
            phase: Phase::Listening(advertised),
            lines: VecDeque::new(),
        }
    }

    /// `event` happened at `at_ms`; the oldest line goes once there are
    /// [`SERVE_LINES`].
    fn record(&mut self, at_ms: i64, event: ServeEventView) {
        self.lines.push_front(ServeLineView { at_ms, event });
        self.lines.truncate(SERVE_LINES);
    }

    /// Serving ended: stopped, or the listener failed with `failure`.
    /// The first end is the one that stands.
    fn ended(&mut self, failure: Option<String>) {
        if let Phase::Listening(_) = self.phase {
            self.phase = failure.map_or(Phase::Stopped, Phase::Failed);
        }
    }

    /// Serving no longer answers: nothing more happens to it.
    fn is_over(&self) -> bool {
        !matches!(self.phase, Phase::Listening(_))
    }

    fn view(&self) -> ServeView {
        ServeView {
            phase: match &self.phase {
                Phase::Listening(advertised) => ServePhaseView::Listening {
                    advertised: advertised.clone(),
                },
                Phase::Stopped => ServePhaseView::Stopped,
                Phase::Failed(message) => ServePhaseView::Failed {
                    message: message.clone(),
                },
            },
            lines: self.lines.iter().cloned().collect(),
        }
    }
}

/// Opens the replica a session's `hello` names, with the root expanded
/// against this host's home - the expansion the grant check uses - as
/// the CLI's agent does, and says which root it serves.
#[derive(Clone)]
struct Opener {
    state: StateDir,
    home: Option<String>,
    tuning: Tuning,
    control: Arc<ServeControl>,
}

impl Opener {
    fn open(
        &self,
        spec: ReplicaSpec,
    ) -> impl Future<Output = Result<LocalReplica, ReplicaError>> + Send + use<> {
        let Opener {
            state,
            home,
            tuning,
            control,
        } = self.clone();
        async move {
            let root = spec
                .expanded_root(home.as_deref())
                .map_err(|error| ReplicaError::Refused(error.to_string()))?;
            control.update(|serving| {
                serving.record(now_ms(), ServeEventView::Serving { root: root.clone() });
            });
            let opening = tokio::task::spawn_blocking(move || {
                LocalReplica::open(root, state, spec.profile, spec.side, spec.jobs, tuning)
            });
            match opening.await {
                Ok(opened) => Ok(opened?),
                Err(error) => match error.try_into_panic() {
                    Ok(panic) => std::panic::resume_unwind(panic),
                    Err(_) => Err(ReplicaError::Refused(
                        "the head shut down while the replica opened".into(),
                    )),
                },
            }
        }
    }
}

fn line(event: PeerEvent) -> ServeEventView {
    match event {
        PeerEvent::Refused { from, why } => ServeEventView::Refused {
            from: from.to_string(),
            message: why.to_string(),
        },
        PeerEvent::Started { from, device, name } => ServeEventView::Started {
            from: from.to_string(),
            device_id: device.to_string(),
            name: name.to_string(),
        },
        PeerEvent::Ended {
            from,
            device,
            name,
            outcome,
        } => ServeEventView::Ended {
            from: from.to_string(),
            device_id: device.to_string(),
            name: name.to_string(),
            failure: outcome.err().map(text),
        },
    }
}

#[cfg(test)]
mod tests {
    use super::{SERVE_LINES, ServeState};
    use crate::views::{ServeEventView, ServePhaseView};

    fn refused(n: usize) -> ServeEventView {
        ServeEventView::Refused {
            from: format!("10.0.0.66:{n}"),
            message: format!("probe {n}"),
        }
    }

    #[test]
    fn a_session_answers_where_it_was_bound_with_nothing_reported() {
        let view = ServeState::new("10.0.0.5:28771".to_owned()).view();
        assert!(matches!(
            view.phase,
            ServePhaseView::Listening { ref advertised } if advertised == "10.0.0.5:28771"
        ));
        assert!(view.lines.is_empty());
    }

    #[test]
    fn lines_are_newest_first_and_bounded_however_many_probes_arrive() {
        let mut state = ServeState::new("x".to_owned());
        for n in 0..100 {
            state.record(i64::try_from(n).unwrap_or(0), refused(n));
        }
        let lines = state.view().lines;
        assert_eq!(lines.len(), SERVE_LINES);
        assert_eq!(lines[0].at_ms, 99);
        assert!(matches!(
            lines[0].event,
            ServeEventView::Refused { ref message, .. } if message == "probe 99"
        ));
    }

    #[test]
    fn serving_ends_stopped_or_failed_and_the_first_end_stands() {
        let mut stopped = ServeState::new("x".to_owned());
        assert!(!stopped.is_over());
        stopped.ended(None);
        assert!(stopped.is_over());
        stopped.ended(Some("aborted".to_owned()));
        assert!(matches!(stopped.view().phase, ServePhaseView::Stopped));

        let mut failed = ServeState::new("x".to_owned());
        failed.ended(Some("accept: too many open files".to_owned()));
        failed.ended(None);
        assert!(failed.is_over());
        assert!(matches!(
            failed.view().phase,
            ServePhaseView::Failed { ref message } if message == "accept: too many open files"
        ));
    }
}
