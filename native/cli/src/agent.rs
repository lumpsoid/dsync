//! `dsync agent` (SPEC §11.1): the far side of a replica connection. Every
//! session's replica is opened here, from its `hello`, with the root
//! expanded against this host's home - the same expansion a peer's grant
//! check uses ([`ReplicaSpec::expanded_root`]).

use std::future::Future;
use std::io::Write;
use std::net::{IpAddr, SocketAddr};
use std::sync::Arc;
use std::time::SystemTime;

use dsync_core::{
    DeviceIdentityStore, LocalReplica, PairedDeviceStore, PeerEvent, PeerListener, ReplicaError,
    ReplicaServer, Root, StateDir, Symlinks, bind_peer,
};
use dsync_domain::host_port::{format_host_port, is_wildcard_address};
use dsync_domain::{HostFacts, ReplicaSpec, Tuning};

use crate::args::{AgentArgs, AgentMode};
use crate::failure::Failure;
use crate::host::Host;
use crate::stop::{STOP_DEADLINE, StopSequence, exit_process, os_signals};

/// Runs `dsync agent`, returning its exit code.
pub async fn agent(args: AgentArgs, host: &Host) -> Result<u8, Failure> {
    let mode = args.mode()?;
    let state = StateDir::resolve(&args.state.choice()?, &host.facts).map_err(Failure::error)?;
    let opener = Opener {
        state: state.clone(),
        home: host.facts.home().map(str::to_owned),
        tuning: Tuning::DEFAULT,
    };
    match mode {
        AgentMode::Stdio => serve_stdio(opener).await,
        AgentMode::Listen(socket) => listen(&socket, opener).await,
        AgentMode::Serve { bind, port } => serve(bind, port, &state, &host.facts, opener).await,
    }
}

/// Opens the replica a session's `hello` names.
#[derive(Clone)]
struct Opener {
    state: StateDir,
    home: Option<String>,
    tuning: Tuning,
}

impl Opener {
    /// Opens `spec`'s replica, going through the `symlinks` it may.
    fn open(
        &self,
        spec: ReplicaSpec,
        symlinks: Symlinks,
    ) -> impl Future<Output = Result<LocalReplica, ReplicaError>> + Send + use<> {
        let Opener {
            state,
            home,
            tuning,
        } = self.clone();
        async move {
            let root = spec
                .expanded_root(home.as_deref())
                .map_err(|error| ReplicaError::Refused(error.to_string()))?;
            let root = Root::new(root, spec.kind, spec.as_path.clone())
                .map_err(|error| ReplicaError::Refused(error.to_string()))?;
            let opening = tokio::task::spawn_blocking(move || {
                LocalReplica::open(
                    root, state, spec.entry, spec.side, spec.jobs, tuning, symlinks,
                )
            });
            match opening.await {
                Ok(opened) => Ok(opened?),
                Err(error) => match error.try_into_panic() {
                    Ok(panic) => std::panic::resume_unwind(panic),
                    Err(_) => Err(ReplicaError::Refused(
                        "the agent shut down while the replica opened".into(),
                    )),
                },
            }
        }
    }
}

/// One session over stdin and stdout, until the initiator closes it: what
/// ssh starts. A clean end is success; a broken one is fatal.
async fn serve_stdio(opener: Opener) -> Result<u8, Failure> {
    let tuning = opener.tuning;
    // Over ssh the user owns both ends: their rules decide (SPEC §4.4).
    let server = ReplicaServer::new(move |spec| opener.open(spec, Symlinks::AsRuled), tuning);
    match server.serve_stdio().await {
        Ok(()) => Ok(0),
        Err(error) => Err(Failure::Fatal(format!("dsync agent: {error}"))),
    }
}

/// Serves every connection on the unix socket at `socket` until a signal,
/// then removes the socket file.
#[cfg(unix)]
async fn listen(socket: &str, opener: Opener) -> Result<u8, Failure> {
    let path = std::path::Path::new(socket);
    let listener = dsync_core::bind_unix(path)
        .await
        .map_err(|error| Failure::Fatal(format!("dsync agent: {error}")))?;
    let stop = watch_stop()?;
    let tuning = opener.tuning;
    // Whoever can open the socket is this host's user (SPEC §4.2).
    let server = Arc::new(ReplicaServer::new(
        move |spec| opener.open(spec, Symlinks::AsRuled),
        tuning,
    ));
    let serving = tokio::spawn(server.serve_unix(listener, |ended| {
        if let Err(error) = ended {
            eprintln!("dsync agent: {error}");
        }
    }));
    eprintln!(
        "dsync agent: listening on {socket}. Anyone who can open this socket can read, write \
         and delete in the replicas served through it, with no further authentication \
         (SPEC §4.2)."
    );
    let code = tokio::select! {
        signal = stop.requested() => signal.exit_code(),
        accepted = serving => match accepted {
            Ok(Err(error)) => {
                let _ = std::fs::remove_file(path);
                return Err(Failure::Fatal(format!("dsync agent: {socket}: {error}")));
            }
            _ => Failure::EXIT_CODE,
        },
    };
    let _ = std::fs::remove_file(path);
    stop.release();
    Ok(code)
}

#[cfg(not(unix))]
async fn listen(_: &str, _: Opener) -> Result<u8, Failure> {
    Err(Failure::Fatal(
        "dsync agent: --listen is not supported on this platform, which has no unix sockets; \
         use --serve"
            .into(),
    ))
}

/// Serves paired devices on `bind:port` until a signal (SPEC §4.4).
async fn serve(
    bind: IpAddr,
    port: u16,
    state: &StateDir,
    facts: &HostFacts,
    opener: Opener,
) -> Result<u8, Failure> {
    let identity = DeviceIdentityStore::new(state)
        .load_or_create(&Host::name(), SystemTime::now())
        .map_err(|error| Failure::Fatal(format!("dsync agent: {error}")))?;
    let listener = bind_peer(bind, port)
        .await
        .map_err(|error| Failure::Fatal(bind_failure(error.address, &error.source.to_string())))?;
    let address = listener.local_addr().map_err(|error| {
        Failure::Fatal(format!(
            "dsync agent: the bound socket has no address: {error}"
        ))
    })?;
    let stop = watch_stop()?;
    let tuning = opener.tuning;
    let peers = Arc::new(PeerListener::new(
        move |spec, symlinks| opener.open(spec, symlinks),
        identity,
        PairedDeviceStore::new(state),
        facts,
        tuning,
    ));
    let serving = tokio::spawn(peers.serve(listener, report));
    eprintln!(
        "dsync agent: serving paired devices on {} (SPEC §4.4). Only devices in `dsync pair \
         list` can connect, each to the roots `dsync pair grant` gave it. Pairing, granting and \
         revoking take effect on the next connection, without a restart.",
        format_host_port(&address.ip().to_string(), address.port())
    );
    let code = tokio::select! {
        signal = stop.requested() => signal.exit_code(),
        accepted = serving => match accepted {
            Ok(Err(error)) => return Err(Failure::Fatal(format!("dsync agent: {error}"))),
            _ => Failure::EXIT_CODE,
        },
    };
    stop.release();
    Ok(code)
}

/// A listener that ends on a signal: the socket is its only state, so the
/// first signal ends it, within the deadline whatever its sessions do.
fn watch_stop() -> Result<StopSequence, Failure> {
    let signals = os_signals()
        .map_err(|error| Failure::Fatal(format!("dsync agent: cannot trap signals: {error}")))?;
    Ok(StopSequence::watch(signals, STOP_DEADLINE, exit_process))
}

/// What the agent's log says about one peer connection: refusals and
/// failed sessions. A session that ends cleanly is not news.
fn report(event: PeerEvent) {
    let mut err = std::io::stderr().lock();
    let _ = match event {
        PeerEvent::Refused { from, why } => writeln!(err, "dsync agent: refused {from}: {why}"),
        PeerEvent::Ended {
            from,
            name,
            outcome: Err(error),
            ..
        } => writeln!(err, "dsync agent: {name} ({from}): {error}"),
        PeerEvent::Started { .. } | PeerEvent::Ended { .. } => Ok(()),
    };
}

/// A `--bind` that could not be bound: which address was asked for, and
/// that nothing falls back to another one (SPEC §11.1).
fn bind_failure(address: SocketAddr, cause: &str) -> String {
    let remedy = if is_wildcard_address(address.ip()) {
        "Something else is already bound to that port, or this host has no address of that \
         family — binding :: needs IPv6 enabled."
    } else {
        "This host does not hold that address right now, or something else is already bound \
         to it."
    };
    format!(
        "dsync agent: could not listen on {}: {cause}. {remedy} Nothing was started — --bind \
         is taken literally, with no fallback to another address.",
        format_host_port(&address.ip().to_string(), address.port())
    )
}
