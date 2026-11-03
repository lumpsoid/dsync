//! The one owner of a profile run's order: its entries synced one after
//! another, each over its own connection and its own [`Run`] (its own
//! archive, locks and delete guard), under one stop.
//!
//! Sequential by design: one connection at a time to each device, and
//! each entry closed (its `Run` closes both replicas) before the next
//! connects. An entry that fails or is skipped leaves the rest to sync -
//! unless its device or transport is unreachable, when the rest would
//! each wait out the same timeout, so they are not started.
//!
//! Before any entry, the in-process sides are resolved as their folder
//! locks name them and refused when two nest ([`ResolvedOverlap`]): the
//! profile's text was checked lexically when it loaded, and a symlink or a
//! move since can hide a nesting that text does not show. Only
//! [`ReplicaLocation::Local`] sides are resolved here: an unschemed
//! `host:path` naming this machine is served in-process too, but is
//! checked lexically only. A far side's paths are its host's to resolve.

mod event;
mod record;
mod redial;

use std::future::Future;
use std::io;
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::{Instant, SystemTime};

use dsync_domain::{
    EffectiveOptions, EntryRecord, Mode, PathStyle, Platform, ProfileName, ReplicaLocation,
    RunMetrics, RunRecord, Side, StopSignal, Tuning, first_nesting,
};
use tokio::sync::mpsc;

pub use event::{
    EntryFailure, EntryOutcome, ListedEntry, ProfileEvent, ResolvedOverlap, SkipReason,
};
pub use redial::ReconnectCause;

use crate::connector::{ConnectError, PeerContact};
use crate::replica::Replica;
use crate::replica_lock::canonical_root;
use crate::run::{Decider, Recalled, Run, RunError, RunEvent, RunReport, RunStop, Stopped};
use crate::run_history::RunHistory;
use crate::state_dir::StateDir;
use record::EntryRecorder;
use redial::{Attempt, Verdict, Window, verdict};

/// Each entry's run event channel: small, as the profile's consumer paces
/// the run through it.
const ENTRY_EVENTS: usize = 16;

/// One run of a profile's entries. Built once, executed once.
pub struct ProfileRun {
    events: mpsc::Sender<ProfileEvent>,
    state: StateDir,
    tuning: Tuning,
    home: Option<String>,
    stop: ProfileStop,
    recording: Option<Recording>,
}

/// What a recorded run's [`RunRecord`] says it ran.
struct Recording {
    profile: Option<String>,
    mode: Mode,
}

/// Stops a profile run from outside it. Made before the run, so whoever
/// takes stop requests (a signal handler, the head) can hold it first. The
/// first stop ends the running entry gracefully, as [`RunStop`] does, and
/// starts no further entry; a later one drops the running entry.
#[derive(Clone, Debug, Default)]
pub struct ProfileStop(RunStop);

impl ProfileStop {
    pub fn new() -> ProfileStop {
        ProfileStop::default()
    }

    pub fn stop(&self) {
        self.0.stop();
    }
}

/// What a profile run ended with.
#[derive(Debug)]
pub struct ProfileReport {
    /// One per entry, in order.
    pub entries: Vec<EntryReport>,
    pub stopped: Option<Stopped>,
    /// Why the run's [`RunRecord`] could not be added to the history, when
    /// it was recorded and could not be.
    pub unrecorded: Option<io::Error>,
}

/// How one entry went.
#[derive(Debug)]
pub struct EntryReport {
    pub outcome: EntryOutcome,
    /// Its run's measurements; `None` when it never connected.
    pub metrics: Option<RunMetrics>,
    /// Actions the decider approved: the last attempt's, plus those every
    /// earlier attempt applied (any other is planned again).
    pub planned: usize,
    /// Approved actions that reported an outcome: the last attempt's,
    /// plus those every earlier attempt applied.
    pub finished: usize,
    /// Times a dropped `peer://` side was dialled again.
    pub reconnects: u32,
}

impl EntryReport {
    fn unrun(outcome: EntryOutcome) -> EntryReport {
        EntryReport {
            outcome,
            metrics: None,
            planned: 0,
            finished: 0,
            reconnects: 0,
        }
    }
}

/// What one attempt's run counted of its events.
#[derive(Default)]
struct Counted {
    planned: usize,
    finished: usize,
    /// Finished and applied: what a later attempt does not plan again. A
    /// failed one - every action of a batch the drop failed, say - is.
    applied: usize,
    /// It got past both locks.
    locked: bool,
}

/// One attempt's run: its report and its counts.
struct Ran {
    report: RunReport,
    counted: Counted,
}

/// An entry's attempts before the one running.
#[derive(Default)]
struct Attempts {
    reconnects: u32,
    /// Actions the earlier attempts applied: the running one's plan no
    /// longer holds them, so they are added to its `planned` as well.
    applied_before: usize,
}

impl Attempts {
    /// The entry's report, `last` being its last run: ended as that run
    /// did, unless `outcome` says otherwise.
    fn ended(&self, last: Ran, outcome: Option<EntryOutcome>) -> EntryReport {
        let Ran { report, counted } = last;
        EntryReport {
            outcome: outcome.unwrap_or_else(|| EntryOutcome::of_run(report.summary, report.error)),
            metrics: Some(report.metrics),
            planned: self.applied_before + counted.planned,
            finished: self.applied_before + counted.finished,
            reconnects: self.reconnects,
        }
    }
}

impl ProfileReport {
    /// SPEC §11.5's code for the whole profile, `interrupted_by` being the
    /// signal the caller stopped it for: the signal's, when there is one;
    /// otherwise the worst entry's, so 0 only when every entry synced
    /// cleanly.
    pub fn exit_code(&self, interrupted_by: Option<StopSignal>) -> u8 {
        if let Some(signal) = interrupted_by {
            return signal.exit_code();
        }
        self.entries
            .iter()
            .map(|entry| entry.outcome.exit_code())
            .max()
            .unwrap_or(0)
    }

    /// Actions approved, over every entry.
    pub fn planned(&self) -> usize {
        self.entries.iter().map(|entry| entry.planned).sum()
    }

    /// Approved actions that reported an outcome, over every entry.
    pub fn finished(&self) -> usize {
        self.entries.iter().map(|entry| entry.finished).sum()
    }
}

impl ProfileRun {
    /// A profile run that emits into `events`, keeps each entry's run
    /// marker in `state`, expands a local side's `~` with `home`, and is
    /// stopped by `stop`.
    pub fn new(
        events: mpsc::Sender<ProfileEvent>,
        state: StateDir,
        tuning: Tuning,
        home: Option<String>,
        stop: ProfileStop,
    ) -> ProfileRun {
        ProfileRun {
            events,
            state,
            tuning,
            home,
            stop,
            recording: None,
        }
    }

    /// This run, its [`RunRecord`] appended to the state directory's
    /// [`RunHistory`] once it ends: `profile` its name (`None` for an
    /// ad-hoc pair), `mode` how its plan was decided.
    pub fn recording(self, profile: Option<&ProfileName>, mode: Mode) -> ProfileRun {
        ProfileRun {
            recording: Some(Recording {
                profile: profile.map(|name| name.as_str().to_owned()),
                mode,
            }),
            ..self
        }
    }

    /// Syncs `entries` in order, each connected by `connect` and then run
    /// with `decider` reviewing its plan when it gets there. Refused before
    /// any entry when two in-process sides nest once resolved.
    pub async fn execute<'o, C, F, A, B>(
        self,
        mut connect: C,
        entries: &'o [EffectiveOptions],
        decider: &mut impl Decider,
    ) -> Result<ProfileReport, ResolvedOverlap>
    where
        C: FnMut(&'o EffectiveOptions) -> F,
        F: Future<Output = Result<(A, B, Vec<PeerContact>), ConnectError>>,
        A: Replica,
        B: Replica,
    {
        self.refuse_resolved_overlap(entries).await?;
        let started = SystemTime::now();
        let list = entries.iter().map(listed).collect();
        self.emit(ProfileEvent::Entries { list }).await;
        let mut reports = Vec::with_capacity(entries.len());
        let mut records = Vec::with_capacity(entries.len());
        let mut ended = false;
        for (index, options) in entries.iter().enumerate() {
            let mut recorder = EntryRecorder::default();
            let report = if ended || self.stop.0.requested() {
                EntryReport::unrun(EntryOutcome::NotRun)
            } else {
                self.entry(index, options, &mut connect, decider, &mut recorder)
                    .await
            };
            ended |= report.outcome.ends_profile();
            self.emit(ProfileEvent::EntryFinished {
                entry: index,
                outcome: report.outcome.clone(),
            })
            .await;
            records.push(recorder.finish(options, &report));
            reports.push(report);
        }
        let unrecorded = self.record(started, records).await.err();
        Ok(ProfileReport {
            entries: reports,
            stopped: self.stop.0.stopped(),
            unrecorded,
        })
    }

    /// Appends this run's record to the history, when it is recorded.
    async fn record(&self, started: SystemTime, entries: Vec<EntryRecord>) -> io::Result<()> {
        let Some(recording) = &self.recording else {
            return Ok(());
        };
        let record = RunRecord {
            started_ms: unix_ms(started),
            ended_ms: unix_ms(SystemTime::now()),
            profile: recording.profile.clone(),
            mode: recording.mode,
            stopped: self.stop.0.requested(),
            entries,
        };
        let history = RunHistory::new(&self.state);
        match tokio::task::spawn_blocking(move || history.append(&record)).await {
            Ok(appended) => appended,
            Err(error) => match error.try_into_panic() {
                Ok(panic) => std::panic::resume_unwind(panic),
                Err(_) => Err(io::Error::other(
                    "the runtime shut down while the run was recorded",
                )),
            },
        }
    }

    /// Connects and runs one entry, dialling a dropped `peer://` side
    /// again within its budget ([`redial`]), its attempts answered by one
    /// [`Recalled`] over `decider`. A stop while connecting, or
    /// while waiting to re-dial, abandons the entry: a connect may never
    /// resolve.
    async fn entry<'o, C, F, A, B>(
        &self,
        index: usize,
        options: &'o EffectiveOptions,
        connect: &mut C,
        decider: &mut impl Decider,
        recorder: &mut EntryRecorder,
    ) -> EntryReport
    where
        C: FnMut(&'o EffectiveOptions) -> F,
        F: Future<Output = Result<(A, B, Vec<PeerContact>), ConnectError>>,
        A: Replica,
        B: Replica,
    {
        self.emit(ProfileEvent::EntryConnecting { entry: index })
            .await;
        let (a, b, peers) = match self.connect(options, connect).await {
            None => return EntryReport::unrun(EntryOutcome::NotRun),
            Some(Err(error)) => {
                let failure = self.not_connected(index, error).await;
                return EntryReport::unrun(EntryOutcome::Failed(EntryFailure::Connect(failure)));
            }
            Some(Ok(connected)) => connected,
        };
        // One record of answers for all of this entry's attempts.
        let decider = &mut Recalled::new(decider);
        let peer_sides: Vec<Side> = peers.iter().map(|peer| peer.side).collect();
        self.emit(ProfileEvent::EntryConnected {
            entry: index,
            peers,
        })
        .await;
        let mut ran = self.run(index, a, b, options, decider, recorder).await;
        let mut attempts = Attempts::default();
        let mut attempt = Attempt::First;
        // The window the re-dials share, and the drop that opened it: a
        // re-run that got past its locks closes it, and its own drop opens
        // the next.
        let mut window: Option<(Window, RunError)> = None;
        loop {
            let Some(error) = ran.report.error.clone() else {
                return attempts.ended(ran, None);
            };
            let mut cause = ReconnectCause::Run(error.clone());
            if self.stop.0.requested() || verdict(attempt, &cause, &peer_sides) == Verdict::Final {
                return attempts.ended(ran, None);
            }
            if ran.counted.locked {
                window = None;
            }
            let (open, dropped) =
                window.get_or_insert_with(|| (Window::open(Instant::now(), self.tuning), error));
            let (a, b) = loop {
                let Some(after) = open.next(attempts.reconnects, Instant::now()) else {
                    // The drop says what happened, unless the far side
                    // still held the lock: that is its own outcome.
                    let failure = match cause {
                        ReconnectCause::Run(held) if held.is_held_on(&peer_sides) => held,
                        _ => dropped.clone(),
                    };
                    let outcome = EntryOutcome::Failed(EntryFailure::Run(failure));
                    return attempts.ended(ran, Some(outcome));
                };
                attempts.reconnects += 1;
                self.emit(ProfileEvent::EntryReconnecting {
                    entry: index,
                    attempt: attempts.reconnects,
                    after,
                    cause: cause.clone(),
                })
                .await;
                tokio::select! {
                    biased;
                    () = self.stop.0.until_requested() => {
                        return attempts.ended(ran, Some(EntryOutcome::NotRun));
                    }
                    () = tokio::time::sleep(after) => {}
                }
                match self.connect(options, connect).await {
                    None => return attempts.ended(ran, Some(EntryOutcome::NotRun)),
                    Some(Ok((a, b, peers))) => {
                        self.emit(ProfileEvent::EntryConnected {
                            entry: index,
                            peers,
                        })
                        .await;
                        break (a, b);
                    }
                    Some(Err(error)) => {
                        let failure = Arc::new(error);
                        cause = ReconnectCause::Connect(failure.clone());
                        if verdict(Attempt::Redial, &cause, &peer_sides) == Verdict::Final {
                            self.emit(ProfileEvent::EntryNotConnected {
                                entry: index,
                                failure: failure.clone(),
                            })
                            .await;
                            let outcome = EntryOutcome::Failed(EntryFailure::Connect(failure));
                            return attempts.ended(ran, Some(outcome));
                        }
                    }
                }
            };
            attempts.applied_before += ran.counted.applied;
            ran = self.run(index, a, b, options, decider, recorder).await;
            attempt = Attempt::Redial;
        }
    }

    /// `connect(options)`, abandoned (`None`) at a stop.
    async fn connect<'o, C, F, A, B>(
        &self,
        options: &'o EffectiveOptions,
        connect: &mut C,
    ) -> Option<Result<(A, B, Vec<PeerContact>), ConnectError>>
    where
        C: FnMut(&'o EffectiveOptions) -> F,
        F: Future<Output = Result<(A, B, Vec<PeerContact>), ConnectError>>,
    {
        tokio::select! {
            biased;
            () = self.stop.0.until_requested() => None,
            connected = connect(options) => Some(connected),
        }
    }

    async fn not_connected(&self, index: usize, error: ConnectError) -> Arc<ConnectError> {
        let failure = Arc::new(error);
        self.emit(ProfileEvent::EntryNotConnected {
            entry: index,
            failure: failure.clone(),
        })
        .await;
        failure
    }

    /// One attempt's run of entry `index` over `a` and `b`.
    async fn run<A: Replica, B: Replica>(
        &self,
        index: usize,
        a: A,
        b: B,
        options: &EffectiveOptions,
        decider: &mut impl Decider,
        recorder: &mut EntryRecorder,
    ) -> Ran {
        let (sender, receiver) = mpsc::channel(ENTRY_EVENTS);
        let run = Run::new(sender, self.state.clone(), self.tuning).with_stop(self.stop.0.clone());
        let (report, counted) = tokio::join!(
            run.execute(a, b, options, decider),
            self.forward(index, receiver, recorder),
        );
        Ran { report, counted }
    }

    /// Passes on every event of entry `index`'s run until it ends,
    /// counting the actions approved and those that reported an outcome,
    /// and noting whether it got past its locks: [`RunEvent::Replicas`]
    /// goes out only once both are taken.
    async fn forward(
        &self,
        index: usize,
        mut events: mpsc::Receiver<RunEvent>,
        recorder: &mut EntryRecorder,
    ) -> Counted {
        let mut counted = Counted::default();
        while let Some(event) = events.recv().await {
            recorder.observe(&event);
            match &event {
                RunEvent::Action(_) => counted.planned += 1,
                RunEvent::Result { outcome, .. } => {
                    counted.finished += 1;
                    counted.applied += usize::from(outcome.is_ok());
                }
                RunEvent::Replicas { .. } => counted.locked = true,
                _ => {}
            }
            self.emit(ProfileEvent::Entry {
                entry: index,
                event,
            })
            .await;
        }
        counted
    }

    /// A consumer that dropped its receiver has stopped listening; the run
    /// goes on unobserved, as a [`Run`]'s does.
    async fn emit(&self, event: ProfileEvent) {
        let _ = self.events.send(event).await;
    }

    /// Refuses when two [`ReplicaLocation::Local`] sides nest once
    /// resolved. A side that cannot be expanded or resolved is left out:
    /// its entry's connect or hello reports it.
    async fn refuse_resolved_overlap(
        &self,
        entries: &[EffectiveOptions],
    ) -> Result<(), ResolvedOverlap> {
        let sides: Vec<((usize, Side), PathBuf)> = entries
            .iter()
            .enumerate()
            .flat_map(|(index, options)| {
                Side::BOTH.into_iter().filter_map(move |side| {
                    let ReplicaLocation::Local(_) = options.replica(side) else {
                        return None;
                    };
                    let expanded = options
                        .replica(side)
                        .to_location()
                        .expanded_path(self.home.as_deref())
                        .ok()?;
                    Some(((index, side), PathBuf::from(expanded)))
                })
            })
            .collect();
        let resolved = match tokio::task::spawn_blocking(move || resolve(sides)).await {
            Ok(resolved) => resolved,
            Err(error) => match error.try_into_panic() {
                Ok(panic) => std::panic::resume_unwind(panic),
                Err(_) => panic!("the runtime shut down while a profile's roots resolved"),
            },
        };
        let style = match Platform::HOST {
            Platform::Unix => PathStyle::Posix,
            Platform::Windows => PathStyle::Windows,
        };
        // A name that is not UTF-8 compares by its lossy spelling: at worst
        // two such names read as one and a profile is refused, never let
        // through.
        let texts: Vec<String> = resolved
            .iter()
            .map(|(_, path)| path.to_string_lossy().into_owned())
            .collect();
        let texts: Vec<&str> = texts.iter().map(String::as_str).collect();
        match first_nesting(&texts, style) {
            None => Ok(()),
            Some((first, second)) => Err(ResolvedOverlap {
                first: resolved[first].0,
                first_path: resolved[first].1.clone(),
                second: resolved[second].0,
                second_path: resolved[second].1.clone(),
            }),
        }
    }
}

/// Each side's path as its folder lock names it; those that cannot be
/// resolved are left out.
fn resolve<K>(sides: Vec<(K, PathBuf)>) -> Vec<(K, PathBuf)> {
    sides
        .into_iter()
        .filter_map(|(key, path)| Some((key, canonical_root(Path::new(&path)).ok()?)))
        .collect()
}

/// Milliseconds from the Unix epoch to `at`; 0 for a time before it.
fn unix_ms(at: SystemTime) -> u64 {
    at.duration_since(SystemTime::UNIX_EPOCH)
        .map_or(0, |since| {
            u64::try_from(since.as_millis()).unwrap_or(u64::MAX)
        })
}

fn listed(options: &EffectiveOptions) -> ListedEntry {
    ListedEntry {
        entry_id: options.entry_id.clone(),
        kind: options.kind(),
        a: options.replica(Side::A).to_string(),
        b: options.replica(Side::B).to_string(),
    }
}
