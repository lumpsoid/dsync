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

use std::future::Future;
use std::path::{Path, PathBuf};
use std::sync::Arc;

use dsync_domain::{
    EffectiveOptions, PathStyle, Platform, ReplicaLocation, RunMetrics, Side, StopSignal, Tuning,
    first_nesting,
};
use tokio::sync::mpsc;

pub use event::{
    EntryFailure, EntryOutcome, ListedEntry, ProfileEvent, ResolvedOverlap, SkipReason,
};

use crate::connector::{ConnectError, PeerContact};
use crate::replica::Replica;
use crate::replica_lock::canonical_root;
use crate::run::{Decider, Run, RunEvent, RunStop, Stopped};
use crate::state_dir::StateDir;

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
}

/// How one entry went.
#[derive(Debug)]
pub struct EntryReport {
    pub outcome: EntryOutcome,
    /// Its run's measurements; `None` when it never connected.
    pub metrics: Option<RunMetrics>,
    /// Actions the decider approved.
    pub planned: usize,
    /// Approved actions that reported an outcome.
    pub finished: usize,
}

impl EntryReport {
    fn unrun(outcome: EntryOutcome) -> EntryReport {
        EntryReport {
            outcome,
            metrics: None,
            planned: 0,
            finished: 0,
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
        let list = entries.iter().map(listed).collect();
        self.emit(ProfileEvent::Entries { list }).await;
        let mut reports = Vec::with_capacity(entries.len());
        let mut ended = false;
        for (index, options) in entries.iter().enumerate() {
            let report = if ended || self.stop.0.requested() {
                EntryReport::unrun(EntryOutcome::NotRun)
            } else {
                self.entry(index, options, &mut connect, decider).await
            };
            ended |= report.outcome.ends_profile();
            self.emit(ProfileEvent::EntryFinished {
                entry: index,
                outcome: report.outcome.clone(),
            })
            .await;
            reports.push(report);
        }
        Ok(ProfileReport {
            entries: reports,
            stopped: self.stop.0.stopped(),
        })
    }

    /// Connects and runs one entry. A stop while connecting abandons the
    /// connect: it may never resolve.
    async fn entry<'o, C, F, A, B>(
        &self,
        index: usize,
        options: &'o EffectiveOptions,
        connect: &mut C,
        decider: &mut impl Decider,
    ) -> EntryReport
    where
        C: FnMut(&'o EffectiveOptions) -> F,
        F: Future<Output = Result<(A, B, Vec<PeerContact>), ConnectError>>,
        A: Replica,
        B: Replica,
    {
        self.emit(ProfileEvent::EntryConnecting { entry: index })
            .await;
        let connected = tokio::select! {
            biased;
            () = self.stop.0.until_requested() => None,
            connected = connect(options) => Some(connected),
        };
        let (a, b, peers) = match connected {
            None => return EntryReport::unrun(EntryOutcome::NotRun),
            Some(Err(error)) => {
                let failure = Arc::new(error);
                self.emit(ProfileEvent::EntryNotConnected {
                    entry: index,
                    failure: failure.clone(),
                })
                .await;
                return EntryReport::unrun(EntryOutcome::Failed(EntryFailure::Connect(failure)));
            }
            Some(Ok(connected)) => connected,
        };
        self.emit(ProfileEvent::EntryConnected {
            entry: index,
            peers,
        })
        .await;
        let (sender, receiver) = mpsc::channel(ENTRY_EVENTS);
        let run = Run::new(sender, self.state.clone(), self.tuning).with_stop(self.stop.0.clone());
        let (report, (planned, finished)) = tokio::join!(
            run.execute(a, b, options, decider),
            self.forward(index, receiver),
        );
        EntryReport {
            outcome: EntryOutcome::of_run(report.summary, report.error),
            metrics: Some(report.metrics),
            planned,
            finished,
        }
    }

    /// Passes on every event of entry `index`'s run until it ends,
    /// counting the actions approved and those that reported an outcome.
    async fn forward(&self, index: usize, mut events: mpsc::Receiver<RunEvent>) -> (usize, usize) {
        let (mut planned, mut finished) = (0, 0);
        while let Some(event) = events.recv().await {
            match event {
                RunEvent::Action(_) => planned += 1,
                RunEvent::Result { .. } => finished += 1,
                _ => {}
            }
            self.emit(ProfileEvent::Entry {
                entry: index,
                event,
            })
            .await;
        }
        (planned, finished)
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

fn listed(options: &EffectiveOptions) -> ListedEntry {
    ListedEntry {
        entry_id: options.entry_id.clone(),
        kind: options.kind(),
        a: options.replica(Side::A).to_string(),
        b: options.replica(Side::B).to_string(),
    }
}
