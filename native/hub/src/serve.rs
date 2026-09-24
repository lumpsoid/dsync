//! Serving paired devices (SPEC §4.4) from the head: the CLI's `agent
//! --serve` wiring, each connection's story forwarded as `session`'s
//! [`ServeUpdateBody`]s until the head stops it.

use std::future::Future;
use std::sync::Arc;
use std::time::SystemTime;

use dsync_core::{
    LocalReplica, PeerEvent, PeerListener, ReplicaError, StateDir, bind_peer, interface_addresses,
};
use dsync_domain::host_port::{format_host_port, parse_bind_address};
use dsync_domain::{ReplicaSpec, Tuning, advertised_host, preferred_advertisable_address};

use crate::dispatch::{Handled, Hub, text};
use crate::outbox::Outbox;
use crate::sessions::Session;
use crate::signals::{ReplyResult, ServeUpdateBody};
use crate::views::{AddressesView, ServeStartedView};

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
        let opener = Opener {
            state: self.state.clone(),
            home: self.facts.home().map(str::to_owned),
            tuning: self.tuning,
            out: self.out.clone(),
            session,
        };
        let peers = Arc::new(PeerListener::new(
            move |spec| opener.open(spec),
            identity,
            self.paired(),
            &self.facts,
            self.tuning,
        ));
        let out = self.out.clone();
        self.sessions.spawn(session, Session::Serve, async move {
            let events = out.clone();
            let ended = peers
                .serve(listener, move |event| events.serve(session, update(event)))
                .await;
            out.serve(
                session,
                ServeUpdateBody::Stopped {
                    failure: ended.err().map(text),
                },
            );
        });
        // An unreadable interface list is only a worse guess.
        let interfaces = interface_addresses().unwrap_or_default();
        Ok(ReplyResult::ServeStarted(ServeStartedView {
            port: bound.port(),
            advertised: format_host_port(&advertised_host(None, bind, &interfaces), bound.port()),
            device_id,
        }))
    }

    pub(crate) fn stop_serve(&self, session: u64) -> Handled {
        match self
            .sessions
            .take_if(session, |live| matches!(live, Session::Serve(_)))
        {
            Some(Session::Serve(task)) => {
                task.abort();
                self.out
                    .serve(session, ServeUpdateBody::Stopped { failure: None });
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

/// Opens the replica a session's `hello` names, with the root expanded
/// against this host's home - the expansion the grant check uses - as
/// the CLI's agent does, and says which root it serves.
#[derive(Clone)]
struct Opener {
    state: StateDir,
    home: Option<String>,
    tuning: Tuning,
    out: Outbox,
    session: u64,
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
            out,
            session,
        } = self.clone();
        async move {
            let root = spec
                .expanded_root(home.as_deref())
                .map_err(|error| ReplicaError::Refused(error.to_string()))?;
            out.serve(session, ServeUpdateBody::Serving { root: root.clone() });
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

fn update(event: PeerEvent) -> ServeUpdateBody {
    match event {
        PeerEvent::Refused { from, why } => ServeUpdateBody::Refused {
            from: from.to_string(),
            message: why.to_string(),
        },
        PeerEvent::Started { from, device, name } => ServeUpdateBody::Started {
            from: from.to_string(),
            device_id: device.to_string(),
            name: name.to_string(),
        },
        PeerEvent::Ended {
            from,
            device,
            name,
            outcome,
        } => ServeUpdateBody::Ended {
            from: from.to_string(),
            device_id: device.to_string(),
            name: name.to_string(),
            failure: outcome.err().map(text),
        },
    }
}
