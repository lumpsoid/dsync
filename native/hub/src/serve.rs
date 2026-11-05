//! Serving paired devices (SPEC §4.4) from the head: the CLI's `agent
//! --serve` wiring, each connection's story kept in the session's
//! [`ServeState`] and sent whole as `session`'s snapshots until the head
//! stops it: a phase change at once, connection lines through the
//! session's [`Throttle`], so a port being scanned costs one snapshot per
//! refresh interval however many connections it refuses.

use std::collections::VecDeque;
use std::future::Future;
use std::sync::{Arc, Mutex, MutexGuard, PoisonError};
use std::time::SystemTime;

use dsync_core::{
    DiagnosticsLog, LocalReplica, PeerEvent, PeerListener, ReplicaError, Root, StateDir, Symlinks,
    bind_peer, interface_addresses,
};
use dsync_domain::host_port::{format_host_port, parse_bind_address};
use dsync_domain::{
    ReplicaSpec, SpoolSetting, Tuning, advertised_host, preferred_advertisable_address,
};
use tokio::task::AbortHandle;
use tokio::time::Instant;

use crate::dispatch::{Handled, Hub, text};
use crate::outbox::Outbox;
use crate::sessions::Session;
use crate::signals::ReplyResult;
use crate::throttle::{Throttle, Urgency, Verdict};
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
            shared: Mutex::new(Shared {
                state: ServeState::new(advertised.clone()),
                throttle: Throttle::new(),
            }),
        });
        control.update(|_| Urgency::Now);
        let opener = Opener {
            state: self.state.clone(),
            home: self.facts.home().map(str::to_owned),
            tuning: self.tuning,
            spool: self.spool,
            control: control.clone(),
        };
        let peers = Arc::new(PeerListener::new(
            move |spec, symlinks| opener.open(spec, symlinks),
            identity,
            self.paired(),
            &self.facts,
            self.tuning,
        ));
        let log = DiagnosticsLog::new(&self.state);
        let serving = control.clone();
        let crashed = control.clone();
        self.sessions.spawn(
            session,
            |task| Session::Serve(Serving { task, control }),
            async move {
                let events = serving.clone();
                let ended = peers
                    .serve(listener, move |event| match line(event) {
                        Ok(line) => events.update(|state| state.record(now_ms(), line)),
                        Err(failure) => {
                            let log = log.clone();
                            tokio::task::spawn_blocking(move || log.note(&failure));
                        }
                    })
                    .await;
                serving.update(|state| state.ended(ended.err().map(text)));
            },
            move |message| crashed.update(|state| state.ended(Some(message))),
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

struct Shared {
    state: ServeState,
    throttle: Throttle,
}

/// A serving session's state and where its snapshots go.
pub(crate) struct ServeControl {
    session: u64,
    out: Outbox,
    shared: Mutex<Shared>,
}

impl ServeControl {
    fn lock(&self) -> MutexGuard<'_, Shared> {
        self.shared.lock().unwrap_or_else(PoisonError::into_inner)
    }

    /// Applies `change` and sends what it came to as soon as its urgency
    /// says.
    fn update(self: &Arc<Self>, change: impl FnOnce(&mut ServeState) -> Urgency) {
        let mut shared = self.lock();
        let urgency = change(&mut shared.state);
        match shared.throttle.on(urgency, Instant::now()) {
            Verdict::Send => self.send(&shared),
            Verdict::DeferUntil(at) => {
                let control = self.clone();
                tokio::spawn(async move {
                    tokio::time::sleep_until(at).await;
                    let mut shared = control.lock();
                    if let Verdict::Send = shared.throttle.due(Instant::now()) {
                        control.send(&shared);
                    }
                });
            }
            Verdict::Nothing => {}
        }
    }

    fn send(&self, shared: &Shared) {
        let state = &shared.state;
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
    /// [`SERVE_LINES`]. A line is routine: a burst of them is one
    /// snapshot.
    fn record(&mut self, at_ms: i64, event: ServeEventView) -> Urgency {
        self.lines.push_front(ServeLineView { at_ms, event });
        self.lines.truncate(SERVE_LINES);
        Urgency::Routine
    }

    /// Serving ended: stopped, or the listener failed with `failure`.
    /// The first end is the one that stands, and goes out at once.
    fn ended(&mut self, failure: Option<String>) -> Urgency {
        match self.phase {
            Phase::Listening(_) => {
                self.phase = failure.map_or(Phase::Stopped, Phase::Failed);
                Urgency::Now
            }
            Phase::Stopped | Phase::Failed(_) => Urgency::Unseen,
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
    /// Whether a served root spools what the device's run downloads.
    spool: SpoolSetting,
    control: Arc<ServeControl>,
}

impl Opener {
    /// Opens `spec`'s replica, going through the `symlinks` the listener
    /// allows the connected device.
    fn open(
        &self,
        spec: ReplicaSpec,
        symlinks: Symlinks,
    ) -> impl Future<Output = Result<LocalReplica, ReplicaError>> + Send + use<> {
        let Opener {
            state,
            home,
            tuning,
            spool,
            control,
        } = self.clone();
        async move {
            let root = spec
                .expanded_root(home.as_deref())
                .map_err(|error| ReplicaError::Refused(error.to_string()))?;
            control.update(|serving| {
                serving.record(now_ms(), ServeEventView::Serving { root: root.clone() })
            });
            let root = Root::new(root, spec.kind, spec.as_path.clone())
                .map_err(|error| ReplicaError::Refused(error.to_string()))?;
            Ok(LocalReplica::open(
                root,
                state,
                spec.entry,
                spec.side,
                spec.jobs,
                tuning,
                dsync_core::LocalRules { symlinks, spool },
            ))
        }
    }
}

/// The Serve page's line for `event`, or a failed request's whole story
/// for the diagnostics log: the page shows connections, not requests.
fn line(event: PeerEvent) -> Result<ServeEventView, String> {
    Ok(match event {
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
        PeerEvent::Failed {
            from,
            name,
            failure,
            ..
        } => return Err(format!("serving {name} ({from}): {failure}")),
    })
}

#[cfg(test)]
mod tests {
    use std::sync::{Arc, Mutex};
    use std::time::Duration;

    use tokio::sync::mpsc;

    use super::{SERVE_LINES, ServeControl, ServeState, Shared};
    use crate::outbox::{Outbox, Outgoing};
    use crate::throttle::{REFRESH_INTERVAL, Throttle, Urgency};
    use crate::views::{ServeEventView, ServePhaseView, ServeView};

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
        assert_eq!(stopped.ended(None), Urgency::Now);
        assert!(stopped.is_over());
        assert_eq!(stopped.ended(Some("aborted".to_owned())), Urgency::Unseen);
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

    fn control() -> (Arc<ServeControl>, mpsc::UnboundedReceiver<Outgoing>) {
        let (out, outgoing) = Outbox::channel();
        let control = Arc::new(ServeControl {
            session: 3,
            out,
            shared: Mutex::new(Shared {
                state: ServeState::new("x".to_owned()),
                throttle: Throttle::new(),
            }),
        });
        (control, outgoing)
    }

    fn sent(outgoing: &mut mpsc::UnboundedReceiver<Outgoing>) -> Vec<(ServeView, bool)> {
        let mut views = Vec::new();
        while let Ok(Outgoing::Serve(snapshot)) = outgoing.try_recv() {
            assert_eq!(snapshot.session, 3);
            views.push((snapshot.view, snapshot.last));
        }
        views
    }

    #[tokio::test(start_paused = true)]
    async fn a_port_scan_costs_one_snapshot_per_interval_and_the_end_goes_at_once() {
        let (control, mut outgoing) = control();
        control.update(|_| Urgency::Now);
        for n in 0..1000 {
            control.update(|state| state.record(i64::try_from(n).unwrap_or(0), refused(n)));
        }
        assert_eq!(sent(&mut outgoing).len(), 1, "only the first went at once");
        tokio::time::sleep(REFRESH_INTERVAL + Duration::from_millis(1)).await;
        let flushed = sent(&mut outgoing);
        let [(latest, false)] = &flushed[..] else {
            panic!("one snapshot for the whole scan, got {}", flushed.len());
        };
        assert_eq!(latest.lines[0].at_ms, 999);
        control.update(|state| state.record(1000, refused(1000)));
        control.update(|state| state.ended(None));
        let ended = sent(&mut outgoing);
        let [(view, true)] = &ended[..] else {
            panic!("the end at once, and last");
        };
        assert!(matches!(view.phase, ServePhaseView::Stopped));
        assert_eq!(view.lines[0].at_ms, 1000, "it carries the line held back");
        tokio::time::sleep(REFRESH_INTERVAL * 3).await;
        assert!(sent(&mut outgoing).is_empty(), "nothing after the last");
    }
}
