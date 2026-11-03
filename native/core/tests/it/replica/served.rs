//! A site's replica served by a [`ReplicaServer`] and reached through a
//! [`RemoteReplica`] over `tokio::io::duplex`: the real protocol, both
//! ends in this process, no mocks (plan D4).

use std::future::Future;
use std::io;
use std::pin::Pin;
use std::sync::Arc;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::task::{Context, Poll};
use std::time::Duration;

use dsync_core::{
    LinkError, LocalReplica, RemoteReplica, ReplicaError, ReplicaServer, ServedReads, StateDir,
    Transport,
};
use dsync_domain::{EntryId, Jobs, ReplicaSpec, Side, Tuning};
use tokio::io::{AsyncRead, AsyncWrite, DuplexStream};
use tokio::task::JoinHandle;

use crate::replica::support::{PROFILE, Site, with_deadline};

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
            Ok(LocalReplica::open(
                dsync_core::Root::new(spec.root, spec.kind, spec.as_path.clone()).unwrap(),
                state,
                spec.entry,
                spec.side,
                spec.jobs,
                Tuning::DEFAULT,
                dsync_core::Symlinks::AsRuled,
            ))
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
        let (near, far) = tokio::io::duplex(DUPLEX_BYTES);
        Served::over(site, side, near, Transport::split(far)).await
    }

    /// [`Served::new`], counting the bytes the far side sends: how a test
    /// sees where it stopped sending.
    pub async fn counting(site: &Site, side: Side) -> (Served, Arc<AtomicUsize>) {
        let (near, far) = tokio::io::duplex(DUPLEX_BYTES);
        let (reader, writer) = tokio::io::split(far);
        let sent = Arc::new(AtomicUsize::new(0));
        let writer = Counted {
            inner: writer,
            sent: sent.clone(),
        };
        let served = Served::over(site, side, near, Transport::new(reader, writer)).await;
        (served, sent)
    }

    async fn over<R, W>(site: &Site, side: Side, near: DuplexStream, far: Transport<R, W>) -> Served
    where
        R: AsyncRead + Unpin + Send + 'static,
        W: AsyncWrite + Unpin + Send + 'static,
    {
        let server = ReplicaServer::new(
            open_local(site.state()),
            Tuning::DEFAULT,
            ServedReads::new(&Tuning::DEFAULT),
        );
        let serving = tokio::spawn(async move { server.serve(far).await });
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

/// A writer counting the bytes written through it.
struct Counted<W> {
    inner: W,
    sent: Arc<AtomicUsize>,
}

impl<W: AsyncWrite + Unpin> AsyncWrite for Counted<W> {
    fn poll_write(
        mut self: Pin<&mut Self>,
        cx: &mut Context<'_>,
        bytes: &[u8],
    ) -> Poll<io::Result<usize>> {
        let written = Pin::new(&mut self.inner).poll_write(cx, bytes);
        if let Poll::Ready(Ok(n)) = written {
            self.sent.fetch_add(n, Ordering::SeqCst);
        }
        written
    }

    fn poll_flush(mut self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<io::Result<()>> {
        Pin::new(&mut self.inner).poll_flush(cx)
    }

    fn poll_shutdown(mut self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<io::Result<()>> {
        Pin::new(&mut self.inner).poll_shutdown(cx)
    }
}
