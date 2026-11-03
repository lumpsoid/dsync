//! A replica on the far side of a connection (plan D4, D5): the client of
//! a [`crate::ReplicaServer`], speaking the `Replica` contract over one
//! multiplexed connection.
//!
//! Each operation is an exchange under its own request id, so replies may
//! come back in any order and several operations are outstanding at once,
//! within the [`RequestWindow`]'s rules. Which operations are barriers:
//! `hello`, `lock`, `unlock`, `create_root`, all three scan phases,
//! `remove_empty_dirs` (it reaches ancestors a concurrent write may be
//! about to write into) and `compact`. Windowed, per path: `read` (holding
//! its place until its body is over), `write`, `delete`, and `commit`
//! (under every path its batch carries).

use std::collections::HashMap;
use std::io;
use std::sync::{Arc, Mutex, MutexGuard, PoisonError};
use std::time::Duration;

use dsync_domain::{
    ArchiveCommit, ArchiveFacts, Bucket, BucketCount, BucketDigests, FileMeta, FileState, OnDisk,
    Precondition, RelPath, ReplicaSpec, RootFacts, RuleSet, ScanEntry, Tuning, WriteStats,
};
use tokio::io::{AsyncRead, AsyncWrite, BufReader};
use tokio::sync::oneshot;

use crate::body::Body;
use crate::credit::{self, Credits};
use crate::frame::{Frame, FrameError, Kind};
use crate::inbound::{Dropped, Inbound, Piece};
use crate::link_error::LinkError;
use crate::replica::{
    BucketTicket, DigestTicket, DigestedScan, OpenedScan, Reading, Replica, Settled,
};
use crate::replica_error::ReplicaError;
use crate::request_window::RequestWindow;
use crate::ssh_transport::{SshChild, SshLaunch};
use crate::transport::{
    Liveness, Outbox, OutboxClosed, READ_BUFFER_BYTES, SilenceLimit, Task, Transport, start_writer,
};
use crate::version_handshake::handshake;
use crate::wire::{self, Answer, Reply, Request, WireIo};

/// How long [`RemoteReplica::close`] waits for the far side to end its
/// stream once this side has ended its own.
const CLOSE_GRACE: Duration = Duration::from_secs(2);

pub struct RemoteReplica {
    spec: ReplicaSpec,
    link: Arc<Link>,
    window: RequestWindow,
    tasks: Tasks,
    ssh: Option<Box<SshChild>>,
    /// The far side's writer stats, as its last `unlock` reported them.
    served_stats: Mutex<Option<Box<WriteStats>>>,
}

/// The connection's shared state: the outbox, the credit of the write
/// bodies being sent, and the exchanges waiting on the reader.
struct Link {
    outbox: Outbox,
    credits: Arc<Credits>,
    routes: Mutex<Routes>,
}

struct Routes {
    next_id: u32,
    open: HashMap<u32, Route>,
    /// Why the link ended, once it has: every later exchange fails with it.
    ended: Option<LinkError>,
}

/// Where the reader sends an exchange's frames.
enum Route {
    Reply(oneshot::Sender<Answer>),
    /// A read: its reply, then its body, whose end says what the file
    /// was once read.
    Read {
        reply: Option<oneshot::Sender<Answer>>,
        body: Inbound,
        settle: oneshot::Sender<OnDisk>,
    },
}

/// The reader and writer tasks, stopped when the replica is dropped
/// without [`RemoteReplica::close`]: the transport goes with them, which
/// the far side sees as the connection ending.
struct Tasks {
    reading: Task<()>,
    writing: Task<()>,
}

impl RemoteReplica {
    /// Connects over `transport`: the version handshake, then the reader
    /// and writer run in the background. `spec` goes out with
    /// [`Replica::hello`], which is the first call the far side accepts.
    pub async fn connect<R, W>(
        transport: Transport<R, W>,
        spec: ReplicaSpec,
        tuning: &Tuning,
    ) -> Result<RemoteReplica, LinkError>
    where
        R: AsyncRead + Unpin + Send + 'static,
        W: AsyncWrite + Unpin + Send + 'static,
    {
        let Transport {
            reader,
            mut writer,
            liveness,
        } = transport;
        let silence = liveness.map(|liveness| liveness.silence_limit);
        let mut reader =
            BufReader::with_capacity(READ_BUFFER_BYTES, SilenceLimit::new(reader, silence));
        handshake(&mut reader, &mut writer)
            .await
            .map_err(|error| silent_if_timed_out(error, liveness))?;
        let (outbox, written) = start_writer(
            writer,
            liveness.map(|liveness| liveness.heartbeat),
            tuning.read_ahead_chunk_bytes,
        );
        let link = Arc::new(Link {
            outbox,
            credits: Credits::new(),
            routes: Mutex::new(Routes {
                next_id: 1,
                open: HashMap::new(),
                ended: None,
            }),
        });
        // A link whose reader failed - silent, broken, undecodable - is
        // never written to again: the writer is stopped, so a write stuck
        // behind it on a full outbox (a dead path whose socket no longer
        // drains) fails now rather than when TCP gives up. A clean end of
        // the far side's stream leaves the writer to finish.
        let stop_writing = written.abort_handle();
        let reading = {
            let link = link.clone();
            Task::spawn(async move {
                read_replies(reader, link.clone(), liveness).await;
                if !matches!(link.failure(), LinkError::Closed) {
                    stop_writing.abort();
                }
            })
        };
        let writing = {
            let link = link.clone();
            Task::spawn(async move {
                match written.await {
                    Ok(Ok(())) => {}
                    Ok(Err(error)) => link.end(error.into()),
                    Err(_) => link.end(LinkError::Closed),
                }
            })
        };
        Ok(RemoteReplica {
            spec,
            link,
            window: RequestWindow::new(tuning.request_window),
            tasks: Tasks { reading, writing },
            ssh: None,
            served_stats: Mutex::new(None),
        })
    }

    /// Spawns `launch` (`ssh … -T [user@]host <command> agent --stdio`)
    /// and connects over its stdin and stdout. A connection that fails
    /// before it is up carries what ssh printed on its stderr.
    pub async fn over_ssh(
        launch: &SshLaunch,
        spec: ReplicaSpec,
        tuning: &Tuning,
    ) -> Result<RemoteReplica, LinkError> {
        let (transport, ssh) = launch.spawn()?;
        match RemoteReplica::connect(transport, spec, tuning).await {
            Ok(mut replica) => {
                replica.ssh = Some(Box::new(ssh));
                Ok(replica)
            }
            Err(cause) => Err(LinkError::Ssh {
                cause: Box::new(cause),
                stderr: ssh.finish().await,
            }),
        }
    }

    /// What `ssh` has printed on its stderr lately (the last few lines), for
    /// a failure's diagnostics; empty for any other transport.
    pub fn ssh_stderr(&self) -> Vec<String> {
        self.ssh.as_ref().map_or_else(Vec::new, |ssh| ssh.stderr())
    }

    /// Closes the connection in order: waits for every operation issued
    /// before it, ends this side's stream, and waits for the far side to
    /// end its own (the server finishes what it has in flight, releases
    /// the lock and closes). Then an ssh child is waited for, and killed if
    /// it lingers.
    pub async fn close(mut self) -> Result<(), ReplicaError> {
        let _all = self.window.barrier().await;
        self.link.outbox.close().await;
        let _ = (&mut self.tasks.writing).await;
        // A far side that never closes its end - an ssh whose remote
        // command lingers - is not waited on forever; everything owed was
        // made durable by `unlock` before a run closes.
        if tokio::time::timeout(CLOSE_GRACE, &mut self.tasks.reading)
            .await
            .is_err()
        {
            self.link.end(LinkError::Closed);
        }
        if let Some(ssh) = self.ssh.take() {
            ssh.finish().await;
        }
        match self.link.failure() {
            LinkError::Closed => Ok(()),
            error => Err(error.into()),
        }
    }

    /// One exchange: `request` out, its answer back.
    async fn call(&self, request: Request) -> Result<Reply, ReplicaError> {
        let (id, answer, ()) = self.link.open(|_, reply| (Route::Reply(reply), ()))?;
        self.link
            .send(Frame::new(Kind::Request, id, wire::encode(&request)))
            .await?;
        self.link.answer(answer).await
    }
}

impl Link {
    fn routes(&self) -> MutexGuard<'_, Routes> {
        self.routes.lock().unwrap_or_else(PoisonError::into_inner)
    }

    /// Opens an exchange: its id, where its answer will arrive, and
    /// whatever else `route` made with the id.
    fn open<T>(
        &self,
        route: impl FnOnce(u32, oneshot::Sender<Answer>) -> (Route, T),
    ) -> Result<(u32, oneshot::Receiver<Answer>, T), LinkError> {
        let (answer, answered) = oneshot::channel();
        let mut routes = self.routes();
        if let Some(ended) = &routes.ended {
            return Err(ended.clone());
        }
        let id = routes.next_id;
        // Ids are never reused within a connection's life, except after
        // four billion exchanges; 0 belongs to no request.
        routes.next_id = routes.next_id.checked_add(1).unwrap_or(1);
        let (route, made) = route(id, answer);
        routes.open.insert(id, route);
        Ok((id, answered, made))
    }

    async fn send(&self, frame: Frame) -> Result<(), LinkError> {
        self.outbox
            .send(frame)
            .await
            .map_err(|OutboxClosed| self.failure())
    }

    async fn answer(&self, answered: oneshot::Receiver<Answer>) -> Result<Reply, ReplicaError> {
        match answered.await {
            Ok(Ok(reply)) => Ok(reply),
            Ok(Err(error)) => Err(error.into()),
            Err(_) => Err(self.failure().into()),
        }
    }

    /// Why the link ended; [`LinkError::Closed`] until something says
    /// otherwise.
    fn failure(&self) -> LinkError {
        self.routes().ended.clone().unwrap_or(LinkError::Closed)
    }

    /// Ends the link with `why`, failing every exchange still open: their
    /// answers never come, a body still arriving is cut short, and a body
    /// still being sent stops. The first reason wins.
    fn end(&self, why: LinkError) {
        let open = {
            let mut routes = self.routes();
            routes.ended.get_or_insert(why);
            std::mem::take(&mut routes.open)
        };
        drop(open);
        self.credits.close();
    }

    /// Hands `frame` to the exchange it belongs to.
    fn route(&self, frame: Frame) -> Result<(), LinkError> {
        match frame.kind {
            Kind::Heartbeat => Ok(()),
            Kind::Credit => {
                self.credits.grant(frame.id, credit::granted(&frame)?);
                Ok(())
            }
            Kind::Reply => {
                let answer: Answer = wire::decode(&frame.payload).map_err(|error| {
                    LinkError::Protocol(format!("an undecodable reply: {error}"))
                })?;
                let mut routes = self.routes();
                match routes.open.remove(&frame.id) {
                    Some(Route::Reply(reply)) => {
                        let _ = reply.send(answer);
                    }
                    Some(Route::Read {
                        reply,
                        body,
                        settle,
                    }) => {
                        let failed = answer.is_err();
                        if let Some(reply) = reply {
                            let _ = reply.send(answer);
                        }
                        // A read that failed to open sends no body.
                        if !failed {
                            routes.open.insert(
                                frame.id,
                                Route::Read {
                                    reply: None,
                                    body,
                                    settle,
                                },
                            );
                        }
                    }
                    // The caller gave up on it; nobody is waiting.
                    None => {}
                }
                Ok(())
            }
            Kind::Chunk | Kind::End | Kind::Fail => {
                let (piece, settled) = match frame.kind {
                    Kind::Chunk => (Piece::Chunk(frame.payload), None),
                    Kind::End => {
                        let now = wire::decode::<OnDisk>(&frame.payload).map_err(|error| {
                            LinkError::Protocol(format!("an undecodable read end: {error}"))
                        })?;
                        (Piece::End, Some(now))
                    }
                    _ => (
                        Piece::Fail(wire::decode::<WireIo>(&frame.payload).map_err(|error| {
                            LinkError::Protocol(format!("an undecodable body failure: {error}"))
                        })?),
                        None,
                    ),
                };
                let mut routes = self.routes();
                if let Some(Route::Read { body, .. }) = routes.open.get(&frame.id) {
                    let over = body
                        .push(piece)
                        .map_err(|_| LinkError::Protocol("a body frame past its credit".into()))?;
                    if over
                        && let Some(Route::Read { settle, .. }) = routes.open.remove(&frame.id)
                        && let Some(now) = settled
                    {
                        let _ = settle.send(now);
                    }
                }
                Ok(())
            }
            Kind::Version | Kind::Request | Kind::Cancel => Err(LinkError::Protocol(format!(
                "a {:?} frame from the server",
                frame.kind
            ))),
        }
    }
}

/// The reader: every frame off the transport to its exchange, never
/// waiting on any of them. Ends the link with whatever stopped it.
async fn read_replies<R: AsyncRead + Unpin>(
    mut reader: BufReader<SilenceLimit<R>>,
    link: Arc<Link>,
    liveness: Option<Liveness>,
) {
    let why = loop {
        match Frame::read_from(&mut reader).await {
            Ok(Some(frame)) => {
                if let Err(error) = link.route(frame) {
                    break error;
                }
            }
            Ok(None) => break LinkError::Closed,
            Err(FrameError::Io(error)) => {
                break silent_if_timed_out(error.into(), liveness);
            }
            Err(FrameError::Undecodable { reason, .. }) => {
                break LinkError::Protocol(format!("an undecodable frame: {reason}"));
            }
        }
    };
    link.end(why);
}

/// A read timing out on a transport with a silence limit is the far side
/// going silent.
pub(crate) fn silent_if_timed_out(error: LinkError, liveness: Option<Liveness>) -> LinkError {
    match (&error, liveness) {
        (LinkError::Io(io), Some(liveness)) if io.kind() == io::ErrorKind::TimedOut => {
            LinkError::PeerSilent {
                limit: liveness.silence_limit,
            }
        }
        _ => error,
    }
}

fn unexpected(asked: &str) -> ReplicaError {
    ReplicaError::Link(LinkError::Protocol(format!(
        "the far side answered {asked} with the wrong kind of reply"
    )))
}

impl Replica for RemoteReplica {
    async fn hello(&self) -> Result<RootFacts, ReplicaError> {
        let _all = self.window.barrier().await;
        match self.call(Request::Hello(self.spec.clone())).await? {
            Reply::Hello(facts) => Ok(facts),
            _ => Err(unexpected("hello")),
        }
    }

    async fn lock(&self) -> Result<ArchiveFacts, ReplicaError> {
        let _all = self.window.barrier().await;
        match self.call(Request::Lock).await? {
            Reply::Locked(facts) => Ok(facts),
            _ => Err(unexpected("lock")),
        }
    }

    async fn unlock(&self) -> Result<(), ReplicaError> {
        let _all = self.window.barrier().await;
        match self.call(Request::Unlock).await? {
            Reply::Unlocked(stats) => {
                *self
                    .served_stats
                    .lock()
                    .unwrap_or_else(PoisonError::into_inner) = stats;
                Ok(())
            }
            _ => Err(unexpected("unlock")),
        }
    }

    async fn create_root(&self) -> Result<(), ReplicaError> {
        let _all = self.window.barrier().await;
        done(self.call(Request::CreateRoot).await?, "create_root")
    }

    async fn open_scan(&self, rules: &RuleSet) -> Result<OpenedScan, ReplicaError> {
        let _all = self.window.barrier().await;
        match self.call(Request::OpenScan(rules.clone())).await? {
            Reply::Scan(changed) => Ok(OpenedScan {
                changed,
                next: DigestTicket::issue(),
            }),
            _ => Err(unexpected("open_scan")),
        }
    }

    async fn scan_digests(
        &self,
        _ticket: DigestTicket,
        count: BucketCount,
        peer_changed: &[RelPath],
    ) -> Result<DigestedScan, ReplicaError> {
        let _all = self.window.barrier().await;
        let request = Request::ScanDigests {
            count: count.get(),
            peer_changed: peer_changed.to_vec(),
        };
        match self.call(request).await? {
            Reply::Digests { digests, owed } if digests.len() == count.get() as usize => {
                Ok(DigestedScan {
                    digests: BucketDigests::from_digests(digests),
                    owed,
                    next: BucketTicket::issue(),
                })
            }
            _ => Err(unexpected("scan_digests")),
        }
    }

    async fn scan_buckets(
        &self,
        _ticket: &BucketTicket,
        buckets: &[Bucket],
    ) -> Result<Vec<ScanEntry>, ReplicaError> {
        let _all = self.window.barrier().await;
        let indices = buckets.iter().map(|bucket| bucket.index()).collect();
        match self.call(Request::ScanBuckets(indices)).await? {
            Reply::Buckets(entries) => Ok(entries),
            _ => Err(unexpected("scan_buckets")),
        }
    }

    async fn read(&self, path: &RelPath) -> Result<Reading, ReplicaError> {
        // Held by the body's route until the body is over, so a read costs
        // its place in the window for as long as its bytes are arriving -
        // and, dropped, until the far end has stopped sending them.
        let slot = self.window.enter([path.clone()]).await;
        let (id, answer, reading) = self.link.open(|id, reply| {
            let (inbound, body) =
                Inbound::open(self.link.outbox.clone(), id, slot, Dropped::Cancel);
            let (settle, settled) = Settled::channel();
            let route = Route::Read {
                reply: Some(reply),
                body: inbound,
                settle,
            };
            (route, Reading { body, settled })
        })?;
        self.link
            .send(Frame::new(
                Kind::Request,
                id,
                wire::encode(&Request::Read(path.clone())),
            ))
            .await?;
        match self.link.answer(answer).await? {
            Reply::Opened => Ok(reading),
            _ => Err(unexpected("read")),
        }
    }

    async fn write(
        &self,
        path: &RelPath,
        mut body: Body,
        source: FileState,
        expect: Precondition,
    ) -> Result<FileMeta, ReplicaError> {
        let _slot = self.window.enter([path.clone()]).await;
        let (id, mut answer, ()) = self.link.open(|_, reply| (Route::Reply(reply), ()))?;
        let credit = self.link.credits.open(id);
        let request = Request::Write {
            path: path.clone(),
            source,
            expect,
        };
        self.link
            .send(Frame::new(Kind::Request, id, wire::encode(&request)))
            .await?;
        // The body goes out while the answer is awaited: a far side that
        // fails the write early (its folder cannot be made) answers before
        // the body is done, and the rest of the body is not worth sending -
        // nor waiting for credit for.
        let outbox = &self.link.outbox;
        let sent = loop {
            let next = tokio::select! {
                answered = &mut answer => break Sent::Answered(answered),
                next = body.next() => next,
            };
            let sending = async {
                match next {
                    // Only the connection closing stops a write's body: the
                    // server never cancels one (`Link::route` refuses it).
                    Ok(Some(bytes)) => outbox
                        .send_chunk(id, bytes, &credit)
                        .await
                        .map(|()| false)
                        .map_err(|_| OutboxClosed),
                    Ok(None) => outbox.end(id).await.map(|()| true),
                    Err(error) => outbox.fail(id, &error.into()).await.map(|()| true),
                }
            };
            let sent = tokio::select! {
                answered = &mut answer => break Sent::Answered(answered),
                sent = sending => sent,
            };
            match sent {
                Ok(false) => {}
                Ok(true) => break Sent::Whole,
                Err(OutboxClosed) => break Sent::LinkDown,
            }
        };
        let answered = match sent {
            Sent::Whole => answer.await,
            Sent::Answered(answered) => {
                // Ends the body's route on the far side, which drains it.
                let abandoned = io::Error::other("the write was answered before its body ended");
                let _ = outbox.fail(id, &abandoned).await;
                answered
            }
            Sent::LinkDown => return Err(self.link.failure().into()),
        };
        let reply = match answered {
            Ok(Ok(reply)) => reply,
            Ok(Err(error)) => return Err(error.into()),
            Err(_) => return Err(self.link.failure().into()),
        };
        match reply {
            Reply::Written(landed) => Ok(landed),
            _ => Err(unexpected("write")),
        }
    }

    async fn delete(&self, path: &RelPath, expect: Precondition) -> Result<(), ReplicaError> {
        let _slot = self.window.enter([path.clone()]).await;
        let request = Request::Delete {
            path: path.clone(),
            expect,
        };
        done(self.call(request).await?, "delete")
    }

    async fn remove_empty_dirs(&self, path: &RelPath) -> Result<(), ReplicaError> {
        let _all = self.window.barrier().await;
        done(
            self.call(Request::RemoveEmptyDirs(path.clone())).await?,
            "remove_empty_dirs",
        )
    }

    async fn commit(&self, batch: Vec<ArchiveCommit>) -> Result<(), ReplicaError> {
        let _slot = self
            .window
            .enter(batch.iter().map(|commit| commit.path().clone()))
            .await;
        done(self.call(Request::Commit(batch)).await?, "commit")
    }

    async fn compact(&self) -> Result<(), ReplicaError> {
        let _all = self.window.barrier().await;
        done(self.call(Request::Compact).await?, "compact")
    }

    async fn close(self) -> Result<(), ReplicaError> {
        RemoteReplica::close(self).await
    }

    fn write_stats(&self) -> Option<WriteStats> {
        self.served_stats
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .as_deref()
            .cloned()
    }
}

/// How far a write's body got before its answer.
enum Sent {
    Whole,
    Answered(Result<Answer, oneshot::error::RecvError>),
    LinkDown,
}

fn done(reply: Reply, asked: &str) -> Result<(), ReplicaError> {
    match reply {
        Reply::Done => Ok(()),
        _ => Err(unexpected(asked)),
    }
}

#[cfg(test)]
mod tests {
    //! The client against a hand-driven far side over `tokio::io::duplex`:
    //! the cases of `idle_deadline_channel_test.dart`, on paused time, and
    //! a decode failure after the handshake.

    use std::time::Duration;

    use dsync_domain::{EntryId, FormatVersion, Jobs, ReplicaRoot, Side};
    use tokio::io::{AsyncWriteExt, DuplexStream, ReadHalf, WriteHalf, duplex};
    use tokio::time::Instant;

    use super::*;
    use crate::version_handshake::{PROTOCOL_VERSION, handshake_as};
    use crate::wire::WireError;

    /// The far side, speaking frames by hand.
    struct Peer {
        reader: BufReader<ReadHalf<DuplexStream>>,
        writer: WriteHalf<DuplexStream>,
    }

    impl Peer {
        async fn next(&mut self) -> Frame {
            Frame::read_from(&mut self.reader).await.unwrap().unwrap()
        }

        /// The next frame that is not a heartbeat.
        async fn next_request(&mut self) -> Frame {
            loop {
                let frame = self.next().await;
                if frame.kind != Kind::Heartbeat {
                    return frame;
                }
            }
        }

        async fn send(&mut self, frame: Frame) {
            frame.write_to(&mut self.writer).await.unwrap();
            self.writer.flush().await.unwrap();
        }
    }

    fn spec() -> ReplicaSpec {
        ReplicaSpec {
            root: "~/r".into(),
            kind: dsync_domain::RootKind::Folder,
            as_path: None,
            entry: EntryId::parse("0123456789abcdef0123456789abcdef").unwrap(),
            side: Side::B,
            jobs: Jobs::DEFAULT,
        }
    }

    fn info() -> RootFacts {
        RootFacts {
            archive_path: None,
            root: ReplicaRoot::Present,
        }
    }

    async fn connected(liveness: Option<Liveness>) -> (RemoteReplica, Peer) {
        connected_as(PROTOCOL_VERSION, liveness).await
    }

    /// Connected to a far side speaking `version`.
    async fn connected_as(
        version: FormatVersion,
        liveness: Option<Liveness>,
    ) -> (RemoteReplica, Peer) {
        let (near, far) = duplex(64 * 1024);
        let transport = Transport::split(near);
        let transport = match liveness {
            Some(liveness) => transport.with_liveness(liveness),
            None => transport,
        };
        let (reader, mut writer) = tokio::io::split(far);
        let mut reader = BufReader::new(reader);
        let (client, far_side) = within(REAL, async {
            tokio::join!(
                RemoteReplica::connect(transport, spec(), &Tuning::DEFAULT),
                handshake_as(version, &mut reader, &mut writer)
            )
        })
        .await;
        far_side.unwrap();
        (client.unwrap(), Peer { reader, writer })
    }

    /// A hang's deadline: real seconds for a test on real time, virtual
    /// ones - far past every timer these tests wait out - on paused time.
    async fn within<T>(deadline: Duration, work: impl std::future::Future<Output = T>) -> T {
        tokio::time::timeout(deadline, work)
            .await
            .unwrap_or_else(|_| panic!("did not finish within {deadline:?}"))
    }

    const REAL: Duration = Duration::from_secs(5);
    const VIRTUAL: Duration = Duration::from_secs(300);

    fn network() -> Option<Liveness> {
        Some(Liveness::of(&Tuning::DEFAULT))
    }

    #[tokio::test(start_paused = true)]
    async fn a_heartbeat_goes_out_after_five_idle_seconds() {
        let (_client, mut peer) = connected(network()).await;
        let started = Instant::now();
        let frame = within(VIRTUAL, peer.next()).await;
        assert_eq!(frame, Frame::heartbeat());
        assert_eq!(started.elapsed(), Duration::from_secs(5));
    }

    #[tokio::test(start_paused = true)]
    async fn stdio_and_unix_transports_send_no_heartbeat() {
        let (_client, mut peer) = connected(None).await;
        let waited = tokio::time::timeout(Duration::from_secs(60), peer.next()).await;
        assert!(waited.is_err(), "a frame arrived: {waited:?}");
    }

    #[tokio::test(start_paused = true)]
    async fn a_peer_that_stops_sending_fails_the_call_after_thirty_seconds() {
        let (client, mut peer) = connected(network()).await;
        let started = Instant::now();
        let (said, request) = within(VIRTUAL, async {
            tokio::join!(client.hello(), peer.next_request())
        })
        .await;
        assert_eq!(request.kind, Kind::Request);
        assert!(
            matches!(said, Err(ReplicaError::Link(LinkError::PeerSilent { limit })) if limit == Duration::from_secs(30)),
            "{said:?}"
        );
        assert_eq!(started.elapsed(), Duration::from_secs(30));
    }

    #[tokio::test(start_paused = true)]
    async fn a_busy_peer_that_heartbeats_is_not_reaped() {
        let (client, mut peer) = connected(network()).await;
        let far_side = async {
            let request = peer.next_request().await;
            for _ in 0..12 {
                tokio::time::sleep(Duration::from_secs(5)).await;
                peer.send(Frame::heartbeat()).await;
            }
            let answer: Answer = Ok(Reply::Hello(info()));
            peer.send(Frame::new(Kind::Reply, request.id, wire::encode(&answer)))
                .await;
        };
        let (said, ()) = within(VIRTUAL, async { tokio::join!(client.hello(), far_side) }).await;
        assert_eq!(said.unwrap(), info());
    }

    #[tokio::test]
    async fn an_undecodable_stream_after_the_handshake_is_a_protocol_error_not_a_banner() {
        let (client, mut peer) = connected(None).await;
        let far_side = async {
            peer.next_request().await;
            peer.writer.write_all(b"Welcome\n").await.unwrap();
            peer.writer.flush().await.unwrap();
        };
        let (said, ()) = within(REAL, async { tokio::join!(client.hello(), far_side) }).await;
        assert!(
            matches!(said, Err(ReplicaError::Link(LinkError::Protocol(_)))),
            "{said:?}"
        );
        // The link is over: a later call fails the same way, at once.
        assert!(matches!(
            within(REAL, client.lock()).await,
            Err(ReplicaError::Link(LinkError::Protocol(_)))
        ));
    }

    /// Body bytes the peer receives until nothing more comes for a while.
    async fn body_bytes_until_quiet(peer: &mut Peer) -> usize {
        let mut bytes = 0;
        while let Ok(frame) = tokio::time::timeout(Duration::from_millis(100), peer.next()).await {
            assert_eq!(frame.kind, Kind::Chunk);
            bytes += frame.payload.len();
        }
        bytes
    }

    #[tokio::test]
    async fn a_write_body_stops_at_its_credit_and_goes_on_as_it_is_granted() {
        let (client, mut peer) = connected(None).await;
        // The far side here is a fake that never lands the bytes.
        let source = FileState {
            meta: FileMeta {
                size: 0,
                mtime_us: 0,
                mode: 0o644,
            },
            hash: dsync_domain::ContentHash::from_digest([0; 32]),
        };
        let body = Body::from_bytes(vec![1; 3 * credit::STREAM_CREDIT_BYTES]);
        let f = RelPath::parse("f").unwrap();
        let far_side = async {
            let request = peer.next_request().await;
            assert_eq!(
                body_bytes_until_quiet(&mut peer).await,
                credit::STREAM_CREDIT_BYTES
            );
            peer.send(credit::grant_frame(request.id, 1000)).await;
            assert_eq!(body_bytes_until_quiet(&mut peer).await, 1000);
            let answer: Answer = Err(WireError::Refused("enough".into()));
            peer.send(Frame::new(Kind::Reply, request.id, wire::encode(&answer)))
                .await;
            request.id
        };
        let (wrote, id) = within(REAL, async {
            tokio::join!(
                client.write(&f, body, source, Precondition::Absent),
                far_side
            )
        })
        .await;
        assert!(matches!(wrote, Err(ReplicaError::Refused(_))), "{wrote:?}");
        // Answered early, the write ends its body on the wire as failed.
        let frame = within(REAL, peer.next_request()).await;
        assert_eq!((frame.kind, frame.id), (Kind::Fail, id));
    }

    /// A far side that goes dark mid-push: it reads nothing more, so the
    /// writes' frames back up behind a writer stuck on the full transport
    /// and fill the outbox. The silence limit still ends every write.
    #[tokio::test(start_paused = true)]
    async fn writes_stuck_behind_a_full_outbox_end_at_the_silence_limit() {
        let (client, peer) = connected(network()).await;
        // The far side here is a fake that never lands the bytes.
        let source = FileState {
            meta: FileMeta {
                size: 0,
                mtime_us: 0,
                mode: 0o644,
            },
            hash: dsync_domain::ContentHash::from_digest([0; 32]),
        };
        let paths: Vec<_> = (0..8)
            .map(|n| RelPath::parse(&format!("f{n}")).unwrap())
            .collect();
        let writes = paths.iter().map(|path| {
            let body = Body::from_bytes(vec![1; 3 * credit::STREAM_CREDIT_BYTES]);
            client.write(path, body, source, Precondition::Absent)
        });
        let started = Instant::now();
        let wrote = within(VIRTUAL, futures_util::future::join_all(writes)).await;
        for write in wrote {
            assert!(
                matches!(write, Err(ReplicaError::Link(LinkError::PeerSilent { .. }))),
                "{write:?}"
            );
        }
        assert_eq!(started.elapsed(), Duration::from_secs(30));
        drop(peer);
    }

    #[tokio::test]
    async fn a_read_body_past_its_credit_ends_the_link_as_a_protocol_error() {
        let (client, mut peer) = connected(None).await;
        let f = RelPath::parse("f").unwrap();
        let far_side = async {
            let request = peer.next_request().await;
            let opened: Answer = Ok(Reply::Opened);
            peer.send(Frame::new(Kind::Reply, request.id, wire::encode(&opened)))
                .await;
            peer.send(Frame::new(
                Kind::Chunk,
                request.id,
                vec![0; credit::STREAM_CREDIT_BYTES + 1],
            ))
            .await;
        };
        let (read, ()) = within(REAL, async { tokio::join!(client.read(&f), far_side) }).await;
        assert!(within(REAL, read.unwrap().body.collect()).await.is_err());
        assert!(matches!(
            within(REAL, client.lock()).await,
            Err(ReplicaError::Link(LinkError::Protocol(_)))
        ));
    }

    #[tokio::test]
    async fn a_read_s_end_says_what_its_file_was_once_read() {
        let (client, mut peer) = connected(None).await;
        let f = RelPath::parse("f").unwrap();
        let now = OnDisk::File {
            size: 2,
            mtime_us: 7,
        };
        let far_side = async {
            let request = peer.next_request().await;
            let opened: Answer = Ok(Reply::Opened);
            peer.send(Frame::new(Kind::Reply, request.id, wire::encode(&opened)))
                .await;
            peer.send(Frame::new(Kind::Chunk, request.id, b"hi".to_vec()))
                .await;
            peer.send(Frame::new(Kind::End, request.id, wire::encode(&now)))
                .await;
        };
        let (read, ()) = within(REAL, async { tokio::join!(client.read(&f), far_side) }).await;
        let Reading { body, settled } = read.unwrap();
        assert_eq!(within(REAL, body.collect()).await.unwrap(), b"hi");
        assert_eq!(within(REAL, settled.after()).await, now);
    }

    /// What the far side sees, in order.
    #[derive(Debug, PartialEq)]
    enum Saw {
        Frame(Kind),
        /// Nothing for a while; the far side then fails the first read.
        Quiet,
    }

    /// A read of `f` whose consumer drops
    /// its body after one chunk, then a second read of `f`. What the far
    /// side sees from the drop until the second read's request.
    async fn a_dropped_read_then_another() -> Vec<Saw> {
        let (client, mut peer) = connected(None).await;
        let f = RelPath::parse("f").unwrap();
        let far_side = async {
            let request = peer.next_request().await;
            let opened: Answer = Ok(Reply::Opened);
            peer.send(Frame::new(Kind::Reply, request.id, wire::encode(&opened)))
                .await;
            peer.send(Frame::new(Kind::Chunk, request.id, b"a".to_vec()))
                .await;
            request.id
        };
        let (read, first) = within(REAL, async { tokio::join!(client.read(&f), far_side) }).await;
        let Reading { mut body, .. } = read.unwrap();
        assert_eq!(within(REAL, body.next()).await.unwrap().unwrap(), b"a");
        drop(body);
        peer.send(Frame::new(Kind::Chunk, first, b"b".to_vec()))
            .await;

        let far_side = async {
            let mut saw = Vec::new();
            loop {
                match tokio::time::timeout(Duration::from_millis(100), peer.next_request()).await {
                    Ok(frame) if frame.kind == Kind::Request => {
                        saw.push(Saw::Frame(frame.kind));
                        let refused: Answer = Err(WireError::Refused("done".into()));
                        peer.send(Frame::new(Kind::Reply, frame.id, wire::encode(&refused)))
                            .await;
                        return saw;
                    }
                    Ok(frame) => {
                        assert_eq!(frame.id, first);
                        saw.push(Saw::Frame(frame.kind));
                    }
                    Err(_) => {
                        saw.push(Saw::Quiet);
                        let stopped = io::Error::new(io::ErrorKind::Interrupted, "cancelled");
                        peer.send(Frame::new(
                            Kind::Fail,
                            first,
                            WireIo::encode_failure(&stopped),
                        ))
                        .await;
                    }
                }
            }
        };
        let (second, saw) = within(REAL, async { tokio::join!(client.read(&f), far_side) }).await;
        assert!(matches!(second, Err(ReplicaError::Refused(_))));
        saw
    }

    #[tokio::test]
    async fn a_dropped_read_cancels_and_holds_its_path_until_the_far_side_ends_it() {
        assert_eq!(
            a_dropped_read_then_another().await,
            [
                Saw::Frame(Kind::Cancel),
                Saw::Quiet,
                Saw::Frame(Kind::Request)
            ]
        );
    }

    #[tokio::test]
    async fn a_cancel_from_the_server_is_a_protocol_error() {
        let (client, mut peer) = connected(None).await;
        let far_side = async {
            let request = peer.next_request().await;
            peer.send(Frame::new(Kind::Cancel, request.id, Vec::new()))
                .await;
        };
        let (said, ()) = within(REAL, async { tokio::join!(client.hello(), far_side) }).await;
        assert!(
            matches!(said, Err(ReplicaError::Link(LinkError::Protocol(_)))),
            "{said:?}"
        );
    }

    #[tokio::test]
    async fn replies_arriving_out_of_order_complete_the_right_callers() {
        let (client, mut peer) = connected(None).await;
        let (x, y) = (RelPath::parse("x").unwrap(), RelPath::parse("y").unwrap());
        let far_side = async {
            let first = peer.next_request().await;
            let second = peer.next_request().await;
            // Answered last first; each answer names the path it was for.
            for request in [second, first] {
                let Ok(Request::Delete { path, .. }) = wire::decode::<Request>(&request.payload)
                else {
                    panic!("not a delete");
                };
                let answer: Answer = Err(WireError::Refused(path.to_string()));
                peer.send(Frame::new(Kind::Reply, request.id, wire::encode(&answer)))
                    .await;
            }
        };
        let (on_x, on_y, ()) = within(REAL, async {
            tokio::join!(
                client.delete(&x, Precondition::Absent),
                client.delete(&y, Precondition::Absent),
                far_side
            )
        })
        .await;
        assert!(matches!(on_x, Err(ReplicaError::Refused(p)) if p == "x"));
        assert!(matches!(on_y, Err(ReplicaError::Refused(p)) if p == "y"));
    }
}
