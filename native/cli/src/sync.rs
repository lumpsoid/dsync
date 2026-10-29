//! `dsync sync` and `dsync status` (SPEC §11.1): the one owner of a run's
//! order on the command line - resolve the target, connect both replicas,
//! pick the decider and the renderer, run under the stop sequence, and
//! turn what happened into SPEC §11.5's exit code.

use std::io::{self, IsTerminal, Write};
use std::sync::Arc;
use std::time::SystemTime;

use dsync_core::{
    BatchDecider, Connector, DeviceIdentityStore, DryRunDecider, PairedDeviceStore, PeerDialer,
    PeerSessions, ProfileEvent, ProfileRun, ProfileStop, ProfileStore, RunEvent, StateDir,
    interface_addresses,
};
use dsync_domain::{
    AdHocTarget, Command, DirRule, EffectiveOptions, Flags, Location, Mode, ReplicaLocation,
    RunFlags, Side, StateDirChoice, SyncTarget, Tuning,
};
use tokio::sync::{mpsc, watch};

use crate::failure::Failure;
use crate::host::Host;
use crate::interactive::{InteractiveDecider, NOT_A_TERMINAL};
use crate::render::{HumanRenderer, JsonRenderer, Renderer, RunName, RunView, Wallclock};
use crate::stop::{STOP_DEADLINE, StopSequence, exit_process, interrupt_note, os_signals};

/// Events buffered between the run and the renderer: enough to keep the
/// run from waiting on a terminal line by line, small enough to hold it
/// within the apply's stated bound when output stalls.
const EVENT_BUFFER: usize = 256;

/// Runs `sync`/`status` over `positionals` and `flags`, returning the exit
/// code.
pub async fn sync(
    command: Command,
    positionals: &[String],
    flags: Flags,
    host: &Host,
) -> Result<u8, Failure> {
    let facts = &host.facts;
    let flags =
        RunFlags::validate(command, flags).map_err(|error| Failure::usage(error.to_string()))?;
    let target = match command {
        Command::Sync => SyncTarget::for_sync(positionals, facts.platform()),
        Command::Status => SyncTarget::for_status(positionals).map(SyncTarget::Profile),
    }
    .map_err(|error| Failure::usage(error.to_string()))?;
    if flags.mode == Mode::Interactive && !io::stdin().is_terminal() {
        return Err(Failure::error(NOT_A_TERMINAL));
    }
    let state =
        StateDir::resolve(&StateDirChoice::Rule(DirRule::HOST), facts).map_err(Failure::error)?;
    let (name, entries, addresses) = resolve(&target, &flags, &state, host)?;

    let tuning = Tuning {
        apply_in_flight: flags
            .apply_concurrency
            .map_or(Tuning::DEFAULT.apply_in_flight, usize::from),
        ..Tuning::DEFAULT
    };
    let views: Vec<RunView> = entries
        .iter()
        .map(|options| RunView::of(name.clone(), options, &addresses, &state))
        .collect();
    let mut connector = Connector::new(state.clone(), facts.home().map(str::to_owned), tuning)
        .with_local_addresses(addresses);
    if entries.iter().any(dials_a_peer)
        && let Some(identity) = DeviceIdentityStore::new(&state)
            .load()
            .map_err(Failure::error)?
    {
        connector = connector.with_peers(PeerDialer::new(
            identity,
            PairedDeviceStore::new(&state),
            tuning,
            Arc::new(PeerSessions::new()),
        ));
    }

    let clock = Wallclock {
        now: SystemTime::now(),
        offset: host.utc_offset,
    };
    let mut renderer = if flags.json {
        Renderer::Json(JsonRenderer::new(io::stdout(), views[0].clone()))
    } else {
        let mut human = HumanRenderer::new(
            io::stdout(),
            io::stderr(),
            flags.verbosity,
            views[0].clone(),
            clock,
        );
        human.preamble();
        Renderer::Human(human)
    };

    let signals = os_signals()
        .map_err(|error| Failure::error(format!("cannot trap stop signals: {error}")))?;
    let stop_sequence = StopSequence::watch(signals, STOP_DEADLINE, exit_process);
    let profile_stop = ProfileStop::new();
    let stopping = {
        let stopper = profile_stop.clone();
        let requested = stop_sequence.requested();
        tokio::spawn(async move {
            requested.await;
            stopper.stop();
        })
    };
    let (events, received) = mpsc::channel(EVENT_BUFFER);
    let run = ProfileRun::new(
        events,
        state.clone(),
        tuning,
        facts.home().map(str::to_owned),
        profile_stop,
    );
    let (plan_shown, shown) = watch::channel(0usize);
    let executing = async {
        match flags.mode {
            Mode::DryRun => {
                run.execute(
                    |o| async { connector.connect(o).await.map(|c| (c.a, c.b, c.peers)) },
                    &entries,
                    &mut DryRunDecider,
                )
                .await
            }
            Mode::Batch => {
                run.execute(
                    |o| async { connector.connect(o).await.map(|c| (c.a, c.b, c.peers)) },
                    &entries,
                    &mut BatchDecider,
                )
                .await
            }
            Mode::Interactive => {
                let mut decider = InteractiveDecider::new(
                    tokio::io::BufReader::new(tokio::io::stdin()),
                    io::stdout(),
                    shown,
                );
                run.execute(
                    |o| async { connector.connect(o).await.map(|c| (c.a, c.b, c.peers)) },
                    &entries,
                    &mut decider,
                )
                .await
            }
        }
    };
    let (result, ()) = tokio::join!(executing, show(received, &mut renderer, &views, plan_shown));
    stopping.abort();

    let report = match result {
        Err(overlap) => {
            stop_sequence.release();
            let message = match &name {
                RunName::Profile(profile) => format!("profile \"{profile}\": {overlap}"),
                RunName::AdHoc => overlap.to_string(),
            };
            return Err(Failure::error(message));
        }
        Ok(report) => report,
    };
    renderer.entry_outcomes(&views, &report.entries);
    let interrupted_by = stop_sequence.interrupted_by();
    let mut err = io::stderr().lock();
    if let Some(signal) = interrupted_by {
        let _ = writeln!(
            err,
            "{}",
            interrupt_note(signal, report.planned(), report.finished())
        );
    }
    if flags.timings {
        for (view, entry) in views.iter().zip(&report.entries) {
            if let Some(metrics) = &entry.metrics {
                if views.len() > 1 {
                    let _ = writeln!(err, "{} ↔ {}:", view.a.location, view.b.location);
                }
                let _ = write!(err, "{}", metrics.render());
                if entry.reconnects > 0 {
                    let _ = writeln!(err, "reconnects: {}", entry.reconnects);
                }
            }
        }
    }
    stop_sequence.release();
    Ok(report.exit_code(interrupted_by))
}

/// The run's name, every entry's options and this host's addresses
/// (fetched only when a location's locality depends on them).
fn resolve(
    target: &SyncTarget,
    flags: &RunFlags,
    state: &StateDir,
    host: &Host,
) -> Result<(RunName, Vec<EffectiveOptions>, Vec<String>), Failure> {
    let facts = &host.facts;
    match target {
        SyncTarget::Profile(name) => {
            let profile = ProfileStore::resolve(&DirRule::HOST, facts)
                .map_err(Failure::error)?
                .load(name, facts.platform())
                .map_err(Failure::error)?;
            let entries = profile
                .options(name, flags, facts)
                .map_err(|error| Failure::usage(error.to_string()))?;
            let consults = entries.iter().any(|options| {
                Side::BOTH.iter().any(|&side| {
                    options
                        .replica(side)
                        .to_location()
                        .consults_local_addresses()
                })
            });
            let addresses = if consults {
                local_addresses()?
            } else {
                Vec::new()
            };
            Ok((RunName::Profile(name.clone()), entries, addresses))
        }
        SyncTarget::AdHoc(pair) => {
            let addresses = if pair.consults_local_addresses() {
                local_addresses()?
            } else {
                Vec::new()
            };
            let (first, second) = pinned(pair, state)?;
            let options = EffectiveOptions::for_ad_hoc(first, second, flags, facts, &addresses)
                .map_err(|error| Failure::usage(error.to_string()))?;
            Ok((RunName::AdHoc, vec![options], addresses))
        }
    }
}

/// Both typed locations, a `peer://` one pinned to the device its name is
/// paired as here.
fn pinned(
    pair: &AdHocTarget,
    state: &StateDir,
) -> Result<(ReplicaLocation, ReplicaLocation), Failure> {
    let pin = |location: &Location| {
        let device = match location {
            Location::Peer(peer) => {
                let paired = PairedDeviceStore::new(state)
                    .load()
                    .map_err(Failure::error)?;
                let device = paired.by_name(peer.device()).ok_or_else(|| {
                    Failure::error(format!(
                        "no device named \"{}\" is paired with this host; pair with it first",
                        peer.device()
                    ))
                })?;
                Some(device.device_id())
            }
            _ => None,
        };
        ReplicaLocation::new(location.clone(), device).map_err(Failure::error)
    };
    Ok((pin(pair.first())?, pin(pair.second())?))
}

fn dials_a_peer(options: &EffectiveOptions) -> bool {
    Side::BOTH
        .iter()
        .any(|&side| options.replica(side).peer_device().is_some())
}

fn local_addresses() -> Result<Vec<String>, Failure> {
    let addresses = interface_addresses().map_err(|error| {
        Failure::error(format!("cannot list this machine's addresses: {error}"))
    })?;
    Ok(addresses.iter().map(ToString::to_string).collect())
}

/// Renders every entry's events as the profile run produces them, counting
/// each `Plan` event so the interactive decider can wait for its own -
/// entry 2's prompt must never precede entry 2's plan, which a plain
/// "shown" flag left set by entry 1 could let through.
async fn show<O: Write, E: Write>(
    mut received: mpsc::Receiver<ProfileEvent>,
    renderer: &mut Renderer<O, E>,
    views: &[RunView],
    plan_shown: watch::Sender<usize>,
) {
    let total = views.len();
    let mut plans_shown = 0;
    while let Some(event) = received.recv().await {
        match event {
            ProfileEvent::Entries { list } => renderer.entries_listed(&list),
            ProfileEvent::EntryConnecting { entry } => {
                renderer.enter_entry(entry, total, views[entry].clone());
            }
            ProfileEvent::EntryConnected { peers, .. } => renderer.peer_contacts(&peers),
            ProfileEvent::EntryNotConnected { failure, .. } => {
                renderer.connect_failed(&failure);
            }
            ProfileEvent::Entry { event, .. } => {
                renderer.render(&event);
                if matches!(event, RunEvent::Plan { .. }) {
                    plans_shown += 1;
                    let _ = plan_shown.send(plans_shown);
                }
            }
            ProfileEvent::EntryReconnecting {
                attempt,
                after,
                cause,
                ..
            } => renderer.reconnecting(attempt, after, &cause),
            ProfileEvent::EntryFinished { .. } => {}
        }
    }
}
