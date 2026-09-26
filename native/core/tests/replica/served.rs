//! A site's replica served by a [`ReplicaServer`] and reached through a
//! [`RemoteReplica`] over `tokio::io::duplex`: the real protocol, both
//! ends in this process, no mocks (plan D4).

use std::future::Future;
use std::sync::Arc;
use std::time::Duration;

use dsync_core::{
    LinkError, LocalReplica, RemoteReplica, ReplicaError, ReplicaServer, StateDir, Transport,
};
use dsync_domain::{EntryId, Jobs, ReplicaSpec, Side, Tuning};
use tokio::task::JoinHandle;

use crate::support::{PROFILE, Site, with_deadline};

/// The duplex buffer: small next to a body's credit, so backpressure
/// reaches the far side's writer as it would over a socket.
const DUPLEX_BYTES: usize = 64 * 1024;

pub fn spec(site: &Site, side: Side) -> ReplicaSpec {
    ReplicaSpec {
        root: site.root(side).to_str().unwrap().to_owned(),
        kind: dsync_domain::RootKind::Folder,
        as_path: None,
        entry: EntryId::parse(PROFILE).unwrap(),
        side,
        jobs: Jobs::DEFAULT,
    }
}

/// What `agent --stdio` will do: open the spec's replica on this host.
pub fn open_local(
    state: StateDir,
) -> impl Fn(
    ReplicaSpec,
) -> std::pin::Pin<Box<dyn Future<Output = Result<LocalReplica, ReplicaError>> + Send>>
+ Send
+ Sync
+ 'static {
    move |spec: ReplicaSpec| {
        let state = state.clone();
        Box::pin(async move {
            let opened = tokio::task::spawn_blocking(move || {
                LocalReplica::open(
                    spec.root,
                    state,
                    spec.entry,
                    spec.side,
                    spec.jobs,
                    Tuning::DEFAULT,
                    dsync_core::Symlinks::AsRuled,
                )
            });
            Ok(opened.await.unwrap()?)
        })
    }
}

/// A remote replica and the session serving it.
pub struct Served {
    pub replica: Arc<RemoteReplica>,
    pub serving: JoinHandle<Result<(), LinkError>>,
}

impl Served {
    /// The replica on `side` of `site`, served over a fresh connection.
    pub async fn new(site: &Site, side: Side) -> Served {
        let server = ReplicaServer::new(open_local(site.state()), Tuning::DEFAULT);
        let (near, far) = tokio::io::duplex(DUPLEX_BYTES);
        let serving = tokio::spawn(async move { server.serve(Transport::split(far)).await });
        let replica = with_deadline(
            "connect",
            RemoteReplica::connect(Transport::split(near), spec(site, side), &Tuning::DEFAULT),
        )
        .await
        .unwrap();
        Served {
            replica: Arc::new(replica),
            serving,
        }
    }

    /// Closes the connection in order and waits for the session to end.
    pub async fn close(self) {
        let replica = Arc::into_inner(self.replica).expect("nothing else holds the replica");
        with_deadline("close", replica.close()).await.unwrap();
        with_deadline("the session's end", self.serving)
            .await
            .unwrap()
            .unwrap();
    }
}

/// Whether `work` is still pending after a moment: long enough for an
/// in-process exchange to finish many times over.
pub async fn still_pending<T>(work: &mut JoinHandle<T>) -> bool {
    tokio::time::timeout(Duration::from_millis(100), work)
        .await
        .is_err()
}
