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
    ArchiveCommit, Bucket, BucketCount, BucketDigests, FileMeta, RelPath, ReplicaInfo, ReplicaSpec,
    RuleSet, ScanEntry, Tuning,
};
use tokio::io::{AsyncRead, AsyncWrite, BufReader};
use tokio::sync::oneshot;

use crate::body::Body;
use crate::frame::{Frame, FrameError, Kind};
use crate::inbound::{Budget, Inbound, Piece};
use crate::link_error::LinkError;
use crate::replica::{BucketTicket, DigestTicket, DigestedScan, OpenedScan, Replica};
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
}

/// The connection's shared state: the outbox, and the exchanges waiting
/// on the reader.
struct Link {
    outbox: Outbox,
    budget: Arc<Budget>,
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
    /// A read: its reply, then its body.
    Read {
        reply: Option<oneshot::Sender<Answer>>,
        body: Inbound,
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
            budget: Budget::new(tuning.router_budget_bytes),
            routes: Mutex::new(Routes {
                next_id: 1,
                open: HashMap::new(),
                ended: None,
            }),
        });
        let reading = Task::spawn(read_replies(reader, link.clone(), liveness));
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
        let (id, answer) = self.link.open(Route::Reply)?;
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

    /// Opens an exchange: its id, and where its answer will arrive.
    fn open(
        &self,
        route: impl FnOnce(oneshot::Sender<Answer>) -> Route,
    ) -> Result<(u32, oneshot::Receiver<Answer>), LinkError> {
        let (answer, answered) = oneshot::channel();
        let mut routes = self.routes();
        if let Some(ended) = &routes.ended {
            return Err(ended.clone());
        }
        let id = routes.next_id;
        // Ids are never reused within a connection's life, except after
        // four billion exchanges; 0 belongs to no request.
        routes.next_id = routes.next_id.checked_add(1).unwrap_or(1);
        routes.open.insert(id, route(answer));
        Ok((id, answered))
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
    /// answers never come, and a body still arriving is cut short. The
    /// first reason wins.
    fn end(&self, why: LinkError) {
        let open = {
            let mut routes = self.routes();
            routes.ended.get_or_insert(why);
            std::mem::take(&mut routes.open)
        };
        drop(open);
    }

    /// Hands `frame` to the exchange it belongs to.
    fn route(&self, frame: Frame) -> Result<(), LinkError> {
        match frame.kind {
            Kind::Heartbeat => Ok(()),
            Kind::Reply => {
                let answer: Answer = wire::decode(&frame.payload).map_err(|error| {
                    LinkError::Protocol(format!("an undecodable reply: {error}"))
                })?;
                let mut routes = self.routes();
                match routes.open.remove(&frame.id) {
                    Some(Route::Reply(reply)) => {
                        let _ = reply.send(answer);
                    }
                    Some(Route::Read { reply, body }) => {
                        let failed = answer.is_err();
                        if let Some(reply) = reply {
                            let _ = reply.send(answer);
                        }
                        // A read that failed to open sends no body.
                        if !failed {
                            routes
                                .open
                                .insert(frame.id, Route::Read { reply: None, body });
                        }
                    }
                    // The caller gave up on it; nobody is waiting.
                    None => {}
                }
                Ok(())
            }
            Kind::Chunk | Kind::End | Kind::Fail => {
                let piece = match frame.kind {
                    Kind::Chunk => Piece::Chunk(frame.payload),
                    Kind::End => Piece::End,
                    _ => Piece::Fail(wire::decode::<WireIo>(&frame.payload).map_err(|error| {
                        LinkError::Protocol(format!("an undecodable body failure: {error}"))
                    })?),
                };
                let mut routes = self.routes();
                if let Some(Route::Read { body, .. }) = routes.open.get(&frame.id)
                    && body.push(piece)
                {
                    routes.open.remove(&frame.id);
                }
                Ok(())
            }
            Kind::Version | Kind::Request => Err(LinkError::Protocol(format!(
                "a {:?} frame from the server",
                frame.kind
            ))),
        }
    }
}

/// The reader: every frame off the transport to its exchange, pausing
/// while the bodies being routed hold more than the budget. Ends the link
/// with whatever stopped it.
async fn read_replies<R: AsyncRead + Unpin>(
    mut reader: BufReader<SilenceLimit<R>>,
    link: Arc<Link>,
    liveness: Option<Liveness>,
) {
    let why = loop {
        link.budget.within().await;
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
    async fn hello(&self) -> Result<ReplicaInfo, ReplicaError> {
        let _all = self.window.barrier().await;
        match self.call(Request::Hello(self.spec.clone())).await? {
            Reply::Hello(info) => Ok(info),
            _ => Err(unexpected("hello")),
        }
    }

    async fn lock(&self) -> Result<(), ReplicaError> {
        let _all = self.window.barrier().await;
        done(self.call(Request::Lock).await?, "lock")
    }

    async fn unlock(&self) -> Result<(), ReplicaError> {
        let _all = self.window.barrier().await;
        done(self.call(Request::Unlock).await?, "unlock")
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

    async fn read(&self, path: &RelPath) -> Result<Body, ReplicaError> {
        // Held by the body's route until the body is over, so a read costs
        // its place in the window for as long as its bytes are arriving.
        let slot = self.window.enter([path.clone()]).await;
        let (inbound, body) = Inbound::open(self.link.budget.clone(), slot);
        let (id, answer) = self.link.open(|reply| Route::Read {
            reply: Some(reply),
            body: inbound,
        })?;
        self.link
            .send(Frame::new(
                Kind::Request,
                id,
                wire::encode(&Request::Read(path.clone())),
            ))
            .await?;
        match self.link.answer(answer).await? {
            Reply::Opened => Ok(body),
            _ => Err(unexpected("read")),
        }
    }

    async fn write(
        &self,
        path: &RelPath,
        mut body: Body,
        meta: FileMeta,
    ) -> Result<FileMeta, ReplicaError> {
        let _slot = self.window.enter([path.clone()]).await;
        let (id, mut answer) = self.link.open(Route::Reply)?;
        let request = Request::Write {
            path: path.clone(),
            meta,
        };
        self.link
            .send(Frame::new(Kind::Request, id, wire::encode(&request)))
            .await?;
        // The body goes out while the answer is awaited: a far side that
        // fails the write early (its folder cannot be made) answers before
        // the body is done, and the rest of the body is not worth sending.
        let outbox = &self.link.outbox;
        let sent = loop {
            tokio::select! {
                answered = &mut answer => break Sent::Answered(answered),
                next = body.next() => {
                    let sent = match next {
                        Ok(Some(bytes)) => outbox.send_chunk(id, bytes).await.map(|()| false),
                        Ok(None) => outbox.end(id).await.map(|()| true),
                        Err(error) => outbox.fail(id, &error.into()).await.map(|()| true),
                    };
                    match sent {
                        Ok(false) => {}
                        Ok(true) => break Sent::Whole,
                        Err(OutboxClosed) => break Sent::LinkDown,
                    }
                }
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

    async fn delete(&self, path: &RelPath) -> Result<(), ReplicaError> {
        let _slot = self.window.enter([path.clone()]).await;
        done(self.call(Request::Delete(path.clone())).await?, "delete")
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

    use dsync_domain::{Jobs, ProfileId, ReplicaRoot, Side};
    use tokio::io::{AsyncWriteExt, DuplexStream, ReadHalf, WriteHalf, duplex};
    use tokio::time::Instant;

    use super::*;
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
            profile: ProfileId::parse("0123456789abcdef0123456789abcdef").unwrap(),
            side: Side::B,
            jobs: Jobs::DEFAULT,
        }
    }

    fn info() -> ReplicaInfo {
        ReplicaInfo {
            last_commit: None,
            archive_path: None,
            root: ReplicaRoot::Present,
        }
    }

    async fn connected(liveness: Option<Liveness>) -> (RemoteReplica, Peer) {
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
                handshake(&mut reader, &mut writer)
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

    #[tokio::test]
    async fn replies_arriving_out_of_order_complete_the_right_callers() {
        let (client, mut peer) = connected(None).await;
        let (x, y) = (RelPath::parse("x").unwrap(), RelPath::parse("y").unwrap());
        let far_side = async {
            let first = peer.next_request().await;
            let second = peer.next_request().await;
            // Answered last first; each answer names the path it was for.
            for request in [second, first] {
                let Ok(Request::Delete(path)) = wire::decode::<Request>(&request.payload) else {
                    panic!("not a delete");
                };
                let answer: Answer = Err(WireError::Refused(path.to_string()));
                peer.send(Frame::new(Kind::Reply, request.id, wire::encode(&answer)))
                    .await;
            }
        };
        let (on_x, on_y, ()) = within(REAL, async {
            tokio::join!(client.delete(&x), client.delete(&y), far_side)
        })
        .await;
        assert!(matches!(on_x, Err(ReplicaError::Refused(p)) if p == "x"));
        assert!(matches!(on_y, Err(ReplicaError::Refused(p)) if p == "y"));
    }
}
