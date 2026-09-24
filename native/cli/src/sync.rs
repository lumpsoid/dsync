//! `dsync sync` and `dsync status` (SPEC §11.1): the one owner of a run's
//! order on the command line - resolve the target, connect both replicas,
//! pick the decider and the renderer, run under the stop sequence, and
//! turn what happened into SPEC §11.5's exit code.

use std::io::{self, IsTerminal, Write};
use std::time::SystemTime;

use dsync_core::{
    BatchDecider, Connector, DeviceIdentityStore, DryRunDecider, PairedDeviceStore, PeerDialError,
    PeerDialer, ProfileStore, Run, RunEvent, StateDir, interface_addresses,
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
    let (name, options, addresses) = resolve(&target, &flags, &state, host)?;

    let tuning = Tuning {
        writers: flags
            .apply_concurrency
            .map_or(Tuning::DEFAULT.writers, usize::from),
        ..Tuning::DEFAULT
    };
    let view = RunView::of(name, &options, &addresses, &state);
    let mut connector = Connector::new(state.clone(), facts.home().map(str::to_owned), tuning)
        .with_local_addresses(addresses);
    if dials_a_peer(&options)
        && let Some(identity) = DeviceIdentityStore::new(&state)
            .load()
            .map_err(Failure::error)?
    {
        connector = connector.with_peers(PeerDialer::new(
            identity,
            PairedDeviceStore::new(&state),
            tuning,
        ));
    }

    let clock = Wallclock {
        now: SystemTime::now(),
        offset: host.utc_offset,
    };
    let mut renderer = if flags.json {
        Renderer::Json(JsonRenderer::new(io::stdout(), &view))
    } else {
        let mut human =
            HumanRenderer::new(io::stdout(), io::stderr(), flags.verbosity, &view, clock);
        human.preamble();
        Renderer::Human(human)
    };

    let (a, b) = connector.connect(&options).await.map_err(|error| {
        Failure::error(format!(
            "Cannot reach replica {}: {}",
            crate::render::words::side(error.side),
            error.failure
        ))
    })?;

    let signals = os_signals()
        .map_err(|error| Failure::error(format!("cannot trap stop signals: {error}")))?;
    let stop = StopSequence::watch(signals, STOP_DEADLINE, exit_process);
    let (events, received) = mpsc::channel(EVENT_BUFFER);
    let run = Run::new(events, state, tuning);
    let stopping = {
        let stopper = run.stopper();
        let requested = stop.requested();
        tokio::spawn(async move {
            requested.await;
            stopper.stop();
        })
    };
    let (plan_shown, shown) = watch::channel(false);
    let executing = async {
        match flags.mode {
            Mode::DryRun => run.execute(a, b, &options, &mut DryRunDecider).await,
            Mode::Batch => run.execute(a, b, &options, &mut BatchDecider).await,
            Mode::Interactive => {
                let mut decider = InteractiveDecider::new(
                    tokio::io::BufReader::new(tokio::io::stdin()),
                    io::stdout(),
                    shown,
                );
                run.execute(a, b, &options, &mut decider).await
            }
        }
    };
    let (report, applied) = tokio::join!(executing, show(received, &mut renderer, plan_shown));
    stopping.abort();

    let interrupted_by = stop.interrupted_by();
    let mut err = io::stderr().lock();
    if let Some(signal) = interrupted_by {
        let _ = writeln!(
            err,
            "{}",
            interrupt_note(signal, applied.planned, applied.finished)
        );
    }
    if flags.timings {
        let _ = write!(err, "{}", report.metrics.render());
    }
    stop.release();
    Ok(report.outcome(interrupted_by).exit_code())
}

/// The run's name, options and this host's addresses (fetched only when a
/// location's locality depends on them).
fn resolve(
    target: &SyncTarget,
    flags: &RunFlags,
    state: &StateDir,
    host: &Host,
) -> Result<(RunName, EffectiveOptions, Vec<String>), Failure> {
    let facts = &host.facts;
    match target {
        SyncTarget::Profile(name) => {
            let profile = ProfileStore::resolve(&DirRule::HOST, facts)
                .map_err(Failure::error)?
                .load(name, facts.platform())
                .map_err(Failure::error)?;
            let options = EffectiveOptions::for_profile(name, &profile, flags, facts)
                .map_err(|error| Failure::usage(error.to_string()))?;
            let consults = Side::BOTH.iter().any(|&side| {
                options
                    .replica(side)
                    .to_location()
                    .consults_local_addresses()
            });
            let addresses = if consults {
                local_addresses()?
            } else {
                Vec::new()
            };
            Ok((RunName::Profile(name.clone()), options, addresses))
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
            Ok((RunName::AdHoc, options, addresses))
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
                    Failure::error(PeerDialError::NotPaired(peer.device().clone()))
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

/// How far the apply got, for the interrupt note.
#[derive(Clone, Copy, Debug, Default)]
struct Applied {
    /// Actions the decider approved.
    planned: usize,
    /// Actions that reported an outcome.
    finished: usize,
}

/// Renders every event until the run ends, telling the interactive decider
/// once the plan is on screen.
async fn show<O: Write, E: Write>(
    mut received: mpsc::Receiver<RunEvent>,
    renderer: &mut Renderer<'_, O, E>,
    plan_shown: watch::Sender<bool>,
) -> Applied {
    let mut applied = Applied::default();
    while let Some(event) = received.recv().await {
        renderer.render(&event);
        match event {
            RunEvent::Plan { .. } => {
                let _ = plan_shown.send(true);
            }
            RunEvent::Action(_) => applied.planned += 1,
            RunEvent::Result { .. } => applied.finished += 1,
            _ => {}
        }
    }
    applied
}
