//! Serving a replica over a connection (plan D4, D5): the far end of a
//! [`crate::RemoteReplica`].
//!
//! A session is one connection: the version handshake, then the `hello`
//! prologue - the first request must be `hello`, whose [`ReplicaSpec`]
//! the server's `open` turns into the replica this session serves - then
//! every request dispatched concurrently as it arrives, until the client
//! closes. The replica is dropped with the session, whatever ends it, and
//! its lock with it (RAII): under `--listen` the process outlives each
//! session, and a client that died between `lock` and `unlock` must not
//! leave the replica locked for the life of the agent.

use std::future::Future;
use std::sync::{Arc, Mutex, MutexGuard, PoisonError};

use dsync_domain::{Bucket, BucketCount, RelPath, ReplicaSpec, Tuning};
use tokio::io::{AsyncRead, AsyncWrite, BufReader};
use tokio::sync::{Semaphore, mpsc};
use tokio::task::JoinSet;

use crate::body::Body;
use crate::credit::{self, Credits};
use crate::frame::{Frame, FrameError, Kind};
use crate::inbound::{Dropped, Inbound, Piece};
use crate::link_error::LinkError;
use crate::remote_replica::silent_if_timed_out;
use crate::replica::{BucketTicket, DigestTicket, Replica};
use crate::replica_error::ReplicaError;
use crate::served_reads::ServedReads;
use crate::transport::{
    Liveness, Outbox, READ_BUFFER_BYTES, SilenceLimit, Task, Transport, start_writer,
};
use crate::version_handshake::handshake;
use crate::wire::{self, Answer, Reply, Request, WireError, WireIo};

/// Serves replicas opened by `open`, one per session.
///
/// `open` is the seam where a session's replica is decided: it gets the
/// spec exactly as the client sent it (the root unexpanded) and may refuse
/// with [`ReplicaError::Refused`] before anything touches the filesystem.
///
/// `reads` is shared by every server of one process: its served reads,
/// across all their sessions, are bounded together (SPEC §4.2).
pub struct ReplicaServer<F> {
    open: F,
    tuning: Tuning,
    reads: ServedReads,
}

/// One request as the reader decoded it, with its body for a write.
struct Incoming {
    id: u32,
    request: Result<Request, postcard::Error>,
    body: Option<Body>,
}

impl<F, Opening, R> ReplicaServer<F>
where
    F: Fn(ReplicaSpec) -> Opening + Send + Sync,
    Opening: Future<Output = Result<R, ReplicaError>> + Send,
    R: Replica + 'static,
{
    pub fn new(open: F, tuning: Tuning, reads: ServedReads) -> ReplicaServer<F> {
        ReplicaServer {
            open,
            tuning,
            reads,
        }
    }

    /// Serves one session over `transport` until the client closes it (or
    /// it fails, or the prologue is refused). The session's replica, and
    /// any lock it holds, is released before this returns.
    pub async fn serve<Rd, Wr>(&self, transport: Transport<Rd, Wr>) -> Result<(), LinkError>
    where
        Rd: AsyncRead + Unpin + Send + 'static,
        Wr: AsyncWrite + Unpin + Send + 'static,
    {
        self.serve_until(transport, std::future::pending()).await
    }

    /// [`ReplicaServer::serve`], also ending the session the moment
    /// `until` is ready, as on a connection that died: nothing more is
    /// read or written on it, every request in flight is let finish, and
    /// then the replica and its lock are released. `Ok` when cut so.
    ///
    /// A connection that ends - cut, or failed reading (the client's
    /// silence) - is torn down in one order (SPEC §4.2): the reader
    /// returns, ending every write body still arriving; the writer is
    /// aborted, so a request blocked sending to a link nobody reads gets
    /// its send refused instead of waiting on it forever; the requests in
    /// flight are joined, never aborted, since a write's handler is what
    /// keeps the lock held until its writer has stopped touching the
    /// root; and only then the replica, and its lock, are dropped.
    pub async fn serve_until<Rd, Wr>(
        &self,
        transport: Transport<Rd, Wr>,
        until: impl Future<Output = ()> + Send + 'static,
    ) -> Result<(), LinkError>
    where
        Rd: AsyncRead + Unpin + Send + 'static,
        Wr: AsyncWrite + Unpin + Send + 'static,
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
            self.tuning.read_ahead_chunk_bytes,
        );
        // Requests waiting for a place in the session's window: past this
        // many the reader stops reading, so a client that overruns its
        // window cannot queue without limit.
        let (arrived, incoming) = mpsc::channel(self.tuning.request_window.max(1));
        let credits = Credits::new();
        let mut reading = Task::spawn(read_requests(
            reader,
            arrived,
            outbox.clone(),
            credits.clone(),
            liveness,
            until,
        ));
        let session = self.session(incoming, &outbox, &credits);
        let read = async {
            tokio::pin!(session);
            let (read, session_over) = tokio::select! {
                () = &mut session => {
                    // A session the prologue refused stops reading here;
                    // one the client closed has stopped already.
                    reading.abort();
                    ((&mut reading).await.unwrap_or(Ok(ReadEnd::Closed)), true)
                }
                read = &mut reading => (read.unwrap_or(Ok(ReadEnd::Closed)), false),
            };
            if !matches!(read, Ok(ReadEnd::Closed)) {
                // Nothing on this link will be read again: frames still
                // queued cost nothing to drop, and a request sending one
                // is let go.
                written.abort();
            }
            if !session_over {
                session.await;
            }
            read
        }
        .await;
        if matches!(read, Ok(ReadEnd::Closed)) {
            outbox.close().await;
        }
        drop(outbox);
        let wrote = written.await.unwrap_or(Ok(()));
        read?;
        Ok(wrote?)
    }

    /// The prologue, then every request until the connection ends.
    async fn session(
        &self,
        mut incoming: mpsc::Receiver<Incoming>,
        outbox: &Outbox,
        credits: &Arc<Credits>,
    ) {
        let Some(first) = incoming.recv().await else {
            return;
        };
        let spec = match first.request {
            Ok(Request::Hello(spec)) => spec,
            Ok(_) => {
                let refusal = WireError::Refused("the first request must be hello".into());
                return reply(outbox, first.id, Err(refusal)).await;
            }
            Err(error) => return reply(outbox, first.id, Err(undecodable(&error))).await,
        };
        let opening = async {
            let replica = (self.open)(spec).await?;
            let hello = replica.hello().await;
            Ok::<_, ReplicaError>((replica, hello))
        };
        tokio::pin!(opening);
        let opened = tokio::select! {
            opened = &mut opening => opened,
            // A peer that sends past the prologue without waiting for its
            // answer is one whose later requests cannot safely be guessed
            // at: the session ends.
            _ = incoming.recv() => return,
        };
        let (replica, hello) = match opened {
            Ok(opened) => opened,
            Err(error) => return reply(outbox, first.id, Err(error.into())).await,
        };
        let served = Arc::new(Served {
            replica,
            scan: Mutex::new(ServedScan::Closed),
            outbox: outbox.clone(),
            credits: credits.clone(),
            reads: self.reads.clone(),
        });
        let hello = hello.map(Reply::Hello);
        reply(outbox, first.id, hello.map_err(WireError::from)).await;
        // At most a window of requests served at once (SPEC §4.2): a served
        // read holds a blocking thread until its body is over, so without
        // a bound a client that never grants credit could park every one
        // the process has. One past the window waits here for a place;
        // the reader queues a window's more behind it and then stops
        // reading, so a client that overruns stalls only itself. A
        // read also takes one of the process's places (`ServedReads`),
        // which bounds the blocking threads every session holds together.
        let window = Arc::new(Semaphore::new(self.tuning.request_window.max(1)));
        let mut running = JoinSet::new();
        loop {
            // Nothing closes the window, so this always gets a place; were
            // it closed, the session would simply stop taking requests.
            let Ok(place) = window.clone().acquire_owned().await else {
                break;
            };
            let Some(next) = incoming.recv().await else {
                break;
            };
            let served = served.clone();
            running.spawn(async move {
                let _place = place;
                served.handle(next).await;
            });
            while running.try_join_next().is_some() {}
        }
        while running.join_next().await.is_some() {}
        // `served` - the replica, its lock and its archive - goes here.
    }
}

impl<F> ReplicaServer<F> {
    /// Serves one session over this process's own stdin and stdout: the
    /// far end of an ssh transport (`dsync agent --stdio`), with the
    /// liveness bound: a dead ssh link ends the session and releases its
    /// lock at the silence limit, not when sshd's TCP gives up.
    pub async fn serve_stdio<Opening, R>(&self) -> Result<(), LinkError>
    where
        F: Fn(ReplicaSpec) -> Opening + Send + Sync,
        Opening: Future<Output = Result<R, ReplicaError>> + Send,
        R: Replica + 'static,
    {
        let transport = Transport::new(tokio::io::stdin(), tokio::io::stdout())
            .with_liveness(Liveness::of(&self.tuning));
        self.serve(transport).await
    }
}

/// A session's replica, where its scan exchange stands, the credit of
/// the read bodies it is sending, and the process's places for them.
struct Served<R> {
    replica: R,
    scan: Mutex<ServedScan>,
    outbox: Outbox,
    credits: Arc<Credits>,
    reads: ServedReads,
}

/// The tickets the replica issued, held for the client between its scan
/// calls; the bucket count the client chose travels with the second.
enum ServedScan {
    Closed,
    Opened(DigestTicket),
    Digested(BucketTicket, BucketCount),
}

impl<R: Replica> Served<R> {
    fn scan(&self) -> MutexGuard<'_, ServedScan> {
        self.scan.lock().unwrap_or_else(PoisonError::into_inner)
    }

    /// The exchange's state, taken out for a call that spends or borrows
    /// its ticket; put back with [`Served::set_scan`].
    fn take_scan(&self) -> ServedScan {
        std::mem::replace(&mut *self.scan(), ServedScan::Closed)
    }

    fn set_scan(&self, scan: ServedScan) {
        *self.scan() = scan;
    }

    async fn handle(self: Arc<Self>, incoming: Incoming) {
        let Incoming { id, request, body } = incoming;
        let request = match request {
            Ok(request) => request,
            Err(error) => return reply(&self.outbox, id, Err(undecodable(&error))).await,
        };
        let replica = &self.replica;
        let answer: Result<Reply, ReplicaError> = match request {
            Request::Hello(_) => replica.hello().await.map(Reply::Hello),
            Request::Lock => replica.lock().await.map(Reply::Locked),
            Request::Unlock => replica
                .unlock()
                .await
                .map(|()| Reply::Unlocked(replica.write_stats().map(Box::new))),
            Request::CreateRoot => replica.create_root().await.map(|()| Reply::Done),
            Request::OpenScan(rules) => replica.open_scan(&rules).await.map(|opened| {
                self.set_scan(ServedScan::Opened(opened.next));
                Reply::Scan(opened.changed)
            }),
            Request::ScanDigests {
                count,
                peer_changed,
            } => {
                let Some(count) = BucketCount::new(count) else {
                    let why = format!(
                        "a bucket count of {count}, outside 1..={}",
                        BucketCount::MAX
                    );
                    return reply(&self.outbox, id, Err(protocol(&why))).await;
                };
                let taken = self.take_scan();
                let ticket = match taken {
                    ServedScan::Opened(ticket) => ticket,
                    _ => return reply(&self.outbox, id, Err(WireError::NoScan)).await,
                };
                replica
                    .scan_digests(ticket, count, &peer_changed)
                    .await
                    .map(|digested| {
                        self.set_scan(ServedScan::Digested(digested.next, count));
                        Reply::Digests {
                            digests: digested.digests.as_slice().to_vec(),
                            owed: digested.owed,
                        }
                    })
            }
            Request::ScanBuckets(indices) => {
                let taken = self.take_scan();
                let (ticket, count) = match taken {
                    ServedScan::Digested(ticket, count) => (ticket, count),
                    other => {
                        self.set_scan(other);
                        return reply(&self.outbox, id, Err(WireError::NoScan)).await;
                    }
                };
                let buckets: Option<Vec<Bucket>> = indices
                    .into_iter()
                    .map(|index| count.bucket(index))
                    .collect();
                let answer = match buckets {
                    Some(buckets) => replica.scan_buckets(&ticket, &buckets).await,
                    None => Err(ReplicaError::Link(LinkError::Protocol(
                        "a bucket out of range".into(),
                    ))),
                };
                self.set_scan(ServedScan::Digested(ticket, count));
                answer.map(Reply::Buckets)
            }
            Request::Read(path) => {
                // Taken before the replica starts the read's blocking
                // thread, held until its body is over. A read waiting
                // here holds no thread, and stops waiting with its
                // connection: a cut session must not wait on places
                // other sessions hold before it can let its lock go.
                let place = tokio::select! {
                    place = self.reads.place() => place,
                    () = self.credits.closed() => None,
                };
                let Some(_place) = place else {
                    return;
                };
                return self.serve_read(id, &path).await;
            }
            Request::Write {
                path,
                source,
                expect,
            } => match body {
                Some(body) => replica
                    .write(&path, body, source, expect)
                    .await
                    .map(Reply::Written),
                None => {
                    return reply(&self.outbox, id, Err(protocol("a write without its body")))
                        .await;
                }
            },
            Request::Delete { path, expect } => {
                replica.delete(&path, expect).await.map(|()| Reply::Done)
            }
            Request::RemoveEmptyDirs(path) => {
                replica.remove_empty_dirs(&path).await.map(|()| Reply::Done)
            }
            Request::Commit(batch) => replica.commit(batch).await.map(|()| Reply::Done),
            Request::Compact => replica.compact().await.map(|()| Reply::Done),
        };
        reply(&self.outbox, id, answer.map_err(WireError::from)).await;
    }

    /// Opens `path` and sends its body as it is read, or the failure.
    async fn serve_read(&self, id: u32, path: &RelPath) {
        let reading = match self.replica.read(path).await {
            Ok(reading) => reading,
            Err(error) => return reply(&self.outbox, id, Err(error.into())).await,
        };
        // Open before the reply, so no grant can arrive ahead of it.
        let credit = self.credits.open(id);
        reply(&self.outbox, id, Ok(Reply::Opened)).await;
        // Forwarded as it is read: a local read holds a blocking thread
        // until its body is consumed.
        let _ = self.outbox.send_read(id, reading, credit).await;
    }
}

async fn reply(outbox: &Outbox, id: u32, answer: Answer) {
    let _ = outbox
        .send(Frame::new(Kind::Reply, id, wire::encode(&answer)))
        .await;
}

fn protocol(what: &str) -> WireError {
    WireError::Protocol(what.to_owned())
}

/// A request that did not decode - a path that is not a `RelPath`, a rule
/// that is not a glob - refused before any replica sees it.
fn undecodable(error: &postcard::Error) -> WireError {
    WireError::Protocol(format!("an undecodable request: {error}"))
}

/// How the reader stopped, when it did not fail.
enum ReadEnd {
    /// The client closed its end, or the session stopped taking requests.
    Closed,
    /// The session's `until` was ready.
    Cut,
}

/// The reader: requests to the session, a write's body frames to its
/// body, grants and cancels to the read bodies being sent, until the
/// client closes its end or `until` is ready - wherever the reader is
/// waiting, a frame or the session. Either way every read body still
/// being sent stops, and every write body still arriving ends short.
async fn read_requests<R: AsyncRead + Unpin>(
    reader: BufReader<SilenceLimit<R>>,
    arrived: mpsc::Sender<Incoming>,
    outbox: Outbox,
    credits: Arc<Credits>,
    liveness: Option<Liveness>,
    until: impl Future<Output = ()>,
) -> Result<ReadEnd, LinkError> {
    let read = tokio::select! {
        read = route_requests(reader, arrived, outbox, &credits, liveness) => {
            read.map(|()| ReadEnd::Closed)
        }
        () = until => Ok(ReadEnd::Cut),
    };
    credits.close();
    read
}

async fn route_requests<R: AsyncRead + Unpin>(
    mut reader: BufReader<SilenceLimit<R>>,
    arrived: mpsc::Sender<Incoming>,
    outbox: Outbox,
    credits: &Credits,
    liveness: Option<Liveness>,
) -> Result<(), LinkError> {
    let mut bodies: std::collections::HashMap<u32, Inbound> = std::collections::HashMap::new();
    loop {
        let frame = match Frame::read_from(&mut reader).await {
            Ok(Some(frame)) => frame,
            Ok(None) => return Ok(()),
            Err(FrameError::Io(error)) => return Err(silent_if_timed_out(error.into(), liveness)),
            Err(FrameError::Undecodable { reason, .. }) => {
                return Err(LinkError::Protocol(format!(
                    "an undecodable frame: {reason}"
                )));
            }
        };
        let piece = match frame.kind {
            Kind::Heartbeat => continue,
            Kind::Credit => {
                credits.grant(frame.id, credit::granted(&frame)?);
                continue;
            }
            // For a read no longer being sent - already ended, or never
            // opened - there is nothing to stop.
            Kind::Cancel => {
                credits.cancel(frame.id);
                continue;
            }
            Kind::Request => {
                let request = wire::decode::<Request>(&frame.payload);
                // The body's route opens before the next frame is read, so
                // none of the body can arrive ahead of it.
                let body = matches!(request, Ok(Request::Write { .. })).then(|| {
                    let (inbound, body) =
                        Inbound::open(outbox.clone(), frame.id, (), Dropped::Release);
                    bodies.insert(frame.id, inbound);
                    body
                });
                let incoming = Incoming {
                    id: frame.id,
                    request,
                    body,
                };
                if arrived.send(incoming).await.is_err() {
                    return Ok(());
                }
                continue;
            }
            Kind::Chunk => Piece::Chunk(frame.payload),
            Kind::End => Piece::End,
            Kind::Fail => match wire::decode::<WireIo>(&frame.payload) {
                Ok(error) => Piece::Fail(error),
                Err(error) => {
                    return Err(LinkError::Protocol(format!(
                        "an undecodable body failure: {error}"
                    )));
                }
            },
            Kind::Version | Kind::Reply => {
                return Err(LinkError::Protocol(format!(
                    "a {:?} frame from the client",
                    frame.kind
                )));
            }
        };
        // A body frame for no open route belongs to a write already
        // answered: drained here.
        if let Some(body) = bodies.get(&frame.id) {
            let over = body
                .push(piece)
                .map_err(|_| LinkError::Protocol("a body frame past its credit".into()))?;
            if over {
                bodies.remove(&frame.id);
            }
        }
    }
}

#[cfg(test)]
mod tests {
    //! The server against a hand-driven client over `tokio::io::duplex`:
    //! what only a client that breaks the protocol can reach.

    use std::fs;
    use std::time::{Duration, UNIX_EPOCH};

    use dsync_domain::{
        ArchiveCommit, ArchiveFacts, ContentHash, EntryId, FileMeta, FileState, Jobs, Precondition,
        RelPath, RootFacts, RuleSet, STAGING_DIR, ScanEntry, Side, WriteStats,
    };
    use tokio::io::{AsyncWriteExt, DuplexStream, ReadHalf, WriteHalf, duplex};
    use tokio::sync::{Notify, Semaphore, oneshot};
    use tokio::task::JoinHandle;

    use super::*;
    use crate::local_replica::LocalReplica;
    use crate::replica::{DigestedScan, OpenedScan, Reading};
    use crate::replica_lock::{LockError, RunLocks};
    use crate::state_dir::StateDir;

    const DEADLINE: Duration = Duration::from_secs(5);

    async fn within<T>(deadline: Duration, work: impl Future<Output = T>) -> T {
        tokio::time::timeout(deadline, work)
            .await
            .unwrap_or_else(|_| panic!("did not finish within {deadline:?}"))
    }

    struct Client {
        reader: BufReader<ReadHalf<DuplexStream>>,
        writer: WriteHalf<DuplexStream>,
        next_id: u32,
    }

    impl Client {
        async fn send_raw(&mut self, kind: Kind, payload: Vec<u8>) -> u32 {
            self.next_id += 1;
            Frame::new(kind, self.next_id, payload)
                .write_to(&mut self.writer)
                .await
                .unwrap();
            self.writer.flush().await.unwrap();
            self.next_id
        }

        async fn ask(&mut self, request: &Request) -> Answer {
            self.ask_raw(wire::encode(request)).await
        }

        async fn ask_raw(&mut self, payload: Vec<u8>) -> Answer {
            let id = self.send_raw(Kind::Request, payload).await;
            let frame = within(DEADLINE, Frame::read_from(&mut self.reader))
                .await
                .unwrap()
                .unwrap();
            assert_eq!((frame.kind, frame.id), (Kind::Reply, id));
            wire::decode(&frame.payload).unwrap()
        }

        async fn send_to(&mut self, kind: Kind, id: u32, payload: Vec<u8>) {
            Frame::new(kind, id, payload)
                .write_to(&mut self.writer)
                .await
                .unwrap();
            self.writer.flush().await.unwrap();
        }

        async fn next(&mut self) -> Frame {
            within(DEADLINE, Frame::read_from(&mut self.reader))
                .await
                .unwrap()
                .unwrap()
        }

        /// The next frame, if one comes before the server goes quiet.
        async fn next_if_any(&mut self) -> Option<Frame> {
            tokio::time::timeout(
                Duration::from_millis(200),
                Frame::read_from(&mut self.reader),
            )
            .await
            .ok()
            .map(|frame| frame.unwrap().unwrap())
        }

        /// Opens a read of `path`: its id, once the server said it opened.
        async fn open_read(&mut self, path: &str) -> u32 {
            let request = Request::Read(RelPath::parse(path).unwrap());
            let id = self.send_raw(Kind::Request, wire::encode(&request)).await;
            let frame = self.next().await;
            assert_eq!((frame.kind, frame.id), (Kind::Reply, id));
            assert_eq!(
                wire::decode::<Answer>(&frame.payload).unwrap(),
                Ok(Reply::Opened)
            );
            id
        }

        /// The body bytes of read `id` up to its terminating frame.
        async fn body_to_its_end(&mut self, id: u32) -> (usize, Frame) {
            let mut bytes = 0;
            loop {
                let frame = self.next().await;
                assert_eq!(frame.id, id);
                if frame.kind != Kind::Chunk {
                    return (bytes, frame);
                }
                bytes += frame.payload.len();
            }
        }

        /// Whether the server has closed its end.
        async fn closed(&mut self) -> bool {
            matches!(
                within(DEADLINE, Frame::read_from(&mut self.reader)).await,
                Ok(None)
            )
        }
    }

    struct Site {
        dir: tempfile::TempDir,
        /// What the server is tuned with.
        tuning: Tuning,
        /// The places every session served from this site shares, as
        /// one process's servers do.
        reads: ServedReads,
    }

    impl Site {
        fn new() -> Site {
            let dir = tempfile::tempdir().unwrap();
            fs::create_dir(dir.path().join("root")).unwrap();
            Site {
                dir,
                tuning: Tuning::DEFAULT,
                reads: ServedReads::new(&Tuning::DEFAULT),
            }
        }

        fn spec(&self) -> ReplicaSpec {
            ReplicaSpec {
                root: self.dir.path().join("root").to_str().unwrap().to_owned(),
                kind: dsync_domain::RootKind::Folder,
                as_path: None,
                entry: EntryId::parse("0123456789abcdef0123456789abcdef").unwrap(),
                side: Side::A,
                jobs: Jobs::DEFAULT,
            }
        }

        /// Serves this site's replica over a fresh connection, with a
        /// client already past the handshake.
        async fn serve(
            &self,
            liveness: Option<Liveness>,
        ) -> (Client, JoinHandle<Result<(), LinkError>>) {
            self.serve_over(64 * 1024, liveness, std::future::pending(), |replica| {
                replica
            })
            .await
        }

        /// [`Site::serve`] over a link buffering `link_bytes` each way,
        /// cut when `until` is ready, serving `wrap` of the replica.
        async fn serve_over<R: Replica + 'static>(
            &self,
            link_bytes: usize,
            liveness: Option<Liveness>,
            until: impl Future<Output = ()> + Send + 'static,
            wrap: impl Fn(LocalReplica) -> R + Send + Sync + 'static,
        ) -> (Client, JoinHandle<Result<(), LinkError>>) {
            let state = StateDir::new(self.dir.path().join("state"));
            let server = ReplicaServer::new(
                move |spec: ReplicaSpec| {
                    let replica = wrap(LocalReplica::open(
                        crate::Root::folder(spec.root),
                        state.clone(),
                        spec.entry,
                        spec.side,
                        spec.jobs,
                        Tuning::DEFAULT,
                        crate::Symlinks::AsRuled,
                    ));
                    async move { Ok(replica) }
                },
                self.tuning,
                self.reads.clone(),
            );
            let (near, far) = duplex(link_bytes);
            let transport = Transport::split(near);
            let transport = match liveness {
                Some(liveness) => transport.with_liveness(liveness),
                None => transport,
            };
            let serving = tokio::spawn(async move { server.serve_until(transport, until).await });
            let (reader, mut writer) = tokio::io::split(far);
            let mut reader = BufReader::new(reader);
            within(DEADLINE, handshake(&mut reader, &mut writer))
                .await
                .unwrap();
            let client = Client {
                reader,
                writer,
                next_id: 0,
            };
            (client, serving)
        }

        /// Whether another run could lock this site's replica now.
        fn lock_is_free(&self) -> bool {
            let spec = self.spec();
            let state = StateDir::new(self.dir.path().join("state"));
            let root = self.dir.path().join("root");
            let root = crate::Root::folder(root.display().to_string());
            match RunLocks::acquire(&state, &spec.entry, spec.side, &root) {
                Ok(_) => true,
                Err(
                    LockError::Held { .. }
                    | LockError::FolderInUse { .. }
                    | LockError::RootInUse { .. },
                ) => false,
                Err(error) => panic!("{error}"),
            }
        }

        /// The temps in the root's staging folder.
        fn staged(&self) -> Vec<std::path::PathBuf> {
            match fs::read_dir(self.dir.path().join("root").join(STAGING_DIR)) {
                Ok(entries) => entries.map(|entry| entry.unwrap().path()).collect(),
                Err(_) => Vec::new(),
            }
        }
    }

    #[tokio::test]
    async fn a_path_that_is_not_a_rel_path_is_refused_before_the_replica_sees_it() {
        let site = Site::new();
        let outside = site.dir.path().join("x");
        fs::write(&outside, "outside the root").unwrap();
        fs::create_dir(site.dir.path().join("root/ab")).unwrap();
        fs::write(site.dir.path().join("root/ab/x"), "inside").unwrap();
        let (mut client, serving) = site.serve(None).await;
        assert!(matches!(
            client.ask(&Request::Hello(site.spec())).await,
            Ok(Reply::Hello(_))
        ));

        // "ab/x" and "../x" have the same length, so only the path differs.
        let inside = fs::metadata(site.dir.path().join("root/ab/x")).unwrap();
        let mtime = inside
            .modified()
            .unwrap()
            .duration_since(UNIX_EPOCH)
            .unwrap();
        let valid = wire::encode(&Request::Delete {
            path: RelPath::parse("ab/x").unwrap(),
            expect: Precondition::File {
                size: inside.len(),
                mtime_us: i64::try_from(mtime.as_micros()).unwrap(),
            },
        });
        let at = valid.windows(4).position(|w| w == b"ab/x").unwrap();
        let mut escaping = valid.clone();
        escaping[at..at + 4].copy_from_slice(b"../x");
        let refused = client.ask_raw(escaping).await;
        assert!(
            matches!(&refused, Err(WireError::Protocol(why)) if why.contains("undecodable request")),
            "{refused:?}"
        );
        assert!(outside.exists(), "the escaping delete reached the disk");

        // The session carries on, and the same request with a path inside
        // the root does reach the replica.
        assert_eq!(client.ask_raw(valid).await, Ok(Reply::Done));
        assert!(!site.dir.path().join("root/ab/x").exists());
        drop(client);
        within(DEADLINE, serving).await.unwrap().unwrap();
    }

    #[tokio::test]
    async fn a_first_request_that_is_not_hello_is_refused_and_ends_the_session() {
        let site = Site::new();
        let (mut client, serving) = site.serve(None).await;
        assert!(matches!(
            client.ask(&Request::Lock).await,
            Err(WireError::Refused(why)) if why.contains("hello")
        ));
        assert!(client.closed().await);
        within(DEADLINE, serving).await.unwrap().unwrap();
        // Refused before any replica was opened: no lock, no archive.
        assert!(!site.dir.path().join("state").exists());
    }

    #[tokio::test]
    async fn a_second_request_during_the_prologue_ends_the_session() {
        let site = Site::new();
        let (mut client, serving) = site.serve(None).await;
        client
            .send_raw(Kind::Request, wire::encode(&Request::Hello(site.spec())))
            .await;
        client
            .send_raw(Kind::Request, wire::encode(&Request::Lock))
            .await;
        // Whichever the server saw first - the replica opening or the
        // second request - the session ends without serving the lock.
        loop {
            match within(DEADLINE, Frame::read_from(&mut client.reader)).await {
                Ok(None) => break,
                Ok(Some(frame)) => assert_eq!(frame.id, 1, "the lock was answered"),
                Err(error) => panic!("{error:?}"),
            }
        }
        within(DEADLINE, serving).await.unwrap().unwrap();
    }

    #[tokio::test]
    async fn a_bucket_count_past_the_cap_is_refused_and_the_scan_carries_on() {
        let site = Site::new();
        let (mut client, serving) = site.serve(None).await;
        assert!(matches!(
            client.ask(&Request::Hello(site.spec())).await,
            Ok(Reply::Hello(_))
        ));
        assert!(matches!(
            client.ask(&Request::Lock).await,
            Ok(Reply::Locked(_))
        ));
        assert!(matches!(
            client.ask(&Request::OpenScan(RuleSet::default())).await,
            Ok(Reply::Scan(_))
        ));

        // u32::MAX buckets would be a ~100 GB allocation: refused unread.
        for count in [u32::MAX, BucketCount::MAX + 1] {
            let refused = client
                .ask(&Request::ScanDigests {
                    count,
                    peer_changed: Vec::new(),
                })
                .await;
            assert!(
                matches!(&refused, Err(WireError::Protocol(why)) if why.contains("bucket count")),
                "{refused:?}"
            );
        }

        // The session and its open scan survive: the cap itself is served.
        let digests = client
            .ask(&Request::ScanDigests {
                count: BucketCount::MAX,
                peer_changed: Vec::new(),
            })
            .await;
        assert!(
            matches!(&digests, Ok(Reply::Digests { digests, .. })
                if digests.len() == BucketCount::MAX as usize),
            "{:?}",
            digests
                .as_ref()
                .map(|_| "a reply that is not the cap's digests")
        );
        drop(client);
        within(DEADLINE, serving).await.unwrap().unwrap();
    }

    const BIG: usize = 4 * 1024 * 1024;

    /// A session past its hello over a site with a `BIG` file `big` and a
    /// small file `small`.
    async fn serving_files() -> (Site, Client, JoinHandle<Result<(), LinkError>>) {
        let site = Site::new();
        fs::write(site.dir.path().join("root/big"), vec![7u8; BIG]).unwrap();
        fs::write(site.dir.path().join("root/small"), "small").unwrap();
        let (mut client, serving) = site.serve(None).await;
        assert!(matches!(
            client.ask(&Request::Hello(site.spec())).await,
            Ok(Reply::Hello(_))
        ));
        (site, client, serving)
    }

    fn is_cancelled(frame: &Frame) -> bool {
        let error = wire::decode::<WireIo>(&frame.payload).unwrap();
        frame.kind == Kind::Fail
            && std::io::Error::from(error).kind() == std::io::ErrorKind::Interrupted
    }

    #[tokio::test]
    async fn a_cancel_mid_read_ends_it_with_a_fail_and_no_more_chunks() {
        let (_site, mut client, serving) = serving_files().await;
        let id = client.open_read("big").await;
        let first = client.next().await;
        assert_eq!((first.kind, first.id), (Kind::Chunk, id));
        client
            .send_to(
                Kind::Credit,
                id,
                crate::credit::grant_frame(id, 1 << 20).payload,
            )
            .await;
        client.send_to(Kind::Cancel, id, Vec::new()).await;
        let (bytes, last) = client.body_to_its_end(id).await;
        assert!(is_cancelled(&last), "{last:?}");
        assert!(first.payload.len() + bytes < BIG, "the whole file was sent");
        assert_eq!(client.next_if_any().await, None);
        drop(client);
        within(DEADLINE, serving).await.unwrap().unwrap();
    }

    #[tokio::test]
    async fn a_cancel_reaches_a_read_waiting_on_credit() {
        let (_site, mut client, serving) = serving_files().await;
        let id = client.open_read("big").await;
        let mut sent = 0;
        while sent < crate::credit::STREAM_CREDIT_BYTES {
            let frame = client.next().await;
            assert_eq!((frame.kind, frame.id), (Kind::Chunk, id));
            sent += frame.payload.len();
        }
        // Granted nothing: the server waits on credit until the cancel.
        assert_eq!(client.next_if_any().await, None);
        client.send_to(Kind::Cancel, id, Vec::new()).await;
        let last = client.next().await;
        assert_eq!(last.id, id);
        assert!(is_cancelled(&last), "{last:?}");
        drop(client);
        within(DEADLINE, serving).await.unwrap().unwrap();
    }

    #[tokio::test]
    async fn a_cancel_for_no_read_being_sent_changes_nothing() {
        let (_site, mut client, serving) = serving_files().await;
        let id = client.open_read("small").await;
        let (bytes, end) = client.body_to_its_end(id).await;
        assert_eq!((bytes, end.kind), (5, Kind::End));
        // Late, for a read already ended, and for an id never used.
        client.send_to(Kind::Cancel, id, Vec::new()).await;
        client.send_to(Kind::Cancel, 99, Vec::new()).await;
        assert_eq!(client.next_if_any().await, None);

        let again = client.open_read("small").await;
        let (bytes, end) = client.body_to_its_end(again).await;
        assert_eq!((bytes, end.kind), (5, Kind::End));
        drop(client);
        within(DEADLINE, serving).await.unwrap().unwrap();
    }

    /// Every frame the server sends until it goes quiet: the reads it
    /// opened, in order, and the reads it ended.
    async fn until_quiet(client: &mut Client) -> (Vec<u32>, Vec<u32>) {
        let (mut opened, mut ended) = (Vec::new(), Vec::new());
        while let Some(frame) = client.next_if_any().await {
            match frame.kind {
                Kind::Reply => {
                    assert_eq!(
                        wire::decode::<Answer>(&frame.payload).unwrap(),
                        Ok(Reply::Opened)
                    );
                    opened.push(frame.id);
                }
                Kind::Chunk => {}
                Kind::End | Kind::Fail => ended.push(frame.id),
                other => panic!("{other:?}"),
            }
        }
        (opened, ended)
    }

    #[tokio::test]
    async fn reads_past_the_window_wait_for_a_place_and_pipelined_reads_within_it_are_served() {
        const WINDOW: usize = 4;
        let mut site = Site::new();
        site.tuning.request_window = WINDOW;
        fs::write(site.dir.path().join("root/big"), vec![7u8; BIG]).unwrap();
        fs::write(site.dir.path().join("root/small"), "small").unwrap();
        let (mut client, serving) = site.serve(None).await;
        assert!(matches!(
            client.ask(&Request::Hello(site.spec())).await,
            Ok(Reply::Hello(_))
        ));
        let read = wire::encode(&Request::Read(RelPath::parse("big").unwrap()));

        // Two more reads than the window, none granted past its first
        // credit: each opened one parks a blocking thread waiting for
        // credit, so only the window's worth may be opened.
        let mut ids = Vec::new();
        for _ in 0..WINDOW + 2 {
            ids.push(client.send_raw(Kind::Request, read.clone()).await);
        }
        let (mut opened, ended) = until_quiet(&mut client).await;
        opened.sort_unstable();
        assert_eq!(opened, ids[..WINDOW], "the reads let past the window");
        assert_eq!(ended, Vec::<u32>::new());

        // A place given back lets exactly the next one in.
        client.send_to(Kind::Cancel, ids[0], Vec::new()).await;
        let (opened, ended) = until_quiet(&mut client).await;
        assert_eq!((opened, ended), (vec![ids[WINDOW]], vec![ids[0]]));

        for &id in &ids[1..=WINDOW] {
            client.send_to(Kind::Cancel, id, Vec::new()).await;
        }
        let (opened, ended) = until_quiet(&mut client).await;
        assert_eq!((opened, ended.len()), (vec![ids[WINDOW + 1]], WINDOW));
        client
            .send_to(Kind::Cancel, ids[WINDOW + 1], Vec::new())
            .await;
        assert_eq!(
            until_quiet(&mut client).await,
            (vec![], vec![ids[WINDOW + 1]])
        );

        // A window's worth sent at once, as a client pipelines them, is
        // served whole.
        let small = wire::encode(&Request::Read(RelPath::parse("small").unwrap()));
        let mut pipelined = Vec::new();
        for _ in 0..WINDOW {
            pipelined.push(client.send_raw(Kind::Request, small.clone()).await);
        }
        let (mut opened, mut ended) = until_quiet(&mut client).await;
        opened.sort_unstable();
        ended.sort_unstable();
        assert_eq!((&opened, &ended), (&pipelined, &pipelined));
        drop(client);
        within(DEADLINE, serving).await.unwrap().unwrap();
    }

    /// A session of `site` past its hello.
    async fn hello(site: &Site) -> (Client, JoinHandle<Result<(), LinkError>>) {
        let (mut client, serving) = site.serve(None).await;
        assert!(matches!(
            client.ask(&Request::Hello(site.spec())).await,
            Ok(Reply::Hello(_))
        ));
        (client, serving)
    }

    /// Sends `count` reads of `path` at once: their ids.
    async fn send_reads(client: &mut Client, path: &str, count: usize) -> Vec<u32> {
        let read = wire::encode(&Request::Read(RelPath::parse(path).unwrap()));
        let mut ids = Vec::new();
        for _ in 0..count {
            ids.push(client.send_raw(Kind::Request, read.clone()).await);
        }
        ids
    }

    /// The window of a session, and the places shared by every session:
    /// more than one window, fewer than two.
    const WINDOW: usize = 4;
    const PLACES: usize = 6;

    /// A site of a `BIG` file `big` and a small file `small`, tuned to
    /// [`WINDOW`] and [`PLACES`].
    fn sharing_places() -> Site {
        let mut site = Site::new();
        site.tuning.request_window = WINDOW;
        site.tuning.served_reads = PLACES;
        site.reads = ServedReads::new(&site.tuning);
        fs::write(site.dir.path().join("root/big"), vec![7u8; BIG]).unwrap();
        fs::write(site.dir.path().join("root/small"), "small").unwrap();
        site
    }

    #[tokio::test]
    async fn reads_parked_on_credit_across_sessions_stay_at_the_process_cap() {
        let site = sharing_places();
        let (mut first, first_serving) = hello(&site).await;
        let (mut second, second_serving) = hello(&site).await;

        // Each session parks a full window of reads, none granted past
        // its first credit: the first takes a window of places, the
        // second only what is left of them.
        let parked = send_reads(&mut first, "big", WINDOW).await;
        let (mut opened, _) = until_quiet(&mut first).await;
        opened.sort_unstable();
        assert_eq!(opened, parked);
        let waiting = send_reads(&mut second, "big", WINDOW).await;
        let (mut opened, _) = until_quiet(&mut second).await;
        opened.sort_unstable();
        assert_eq!(opened, waiting[..PLACES - WINDOW], "past the places");

        // A new session's read waits too, though its own window is empty.
        let (mut honest, honest_serving) = hello(&site).await;
        let small = send_reads(&mut honest, "small", 1).await;
        assert_eq!(until_quiet(&mut honest).await, (vec![], vec![]));

        // Places given back go in the order they were asked for: the
        // second session's two waiting reads, then the new session's.
        for &id in &parked[..3] {
            first.send_to(Kind::Cancel, id, Vec::new()).await;
        }
        let (_, ended) = until_quiet(&mut first).await;
        assert_eq!(ended.len(), 3);
        let (mut opened, _) = until_quiet(&mut second).await;
        opened.sort_unstable();
        assert_eq!(opened, waiting[PLACES - WINDOW..]);
        assert_eq!(until_quiet(&mut honest).await, (small.clone(), small));

        drop((first, second, honest));
        for serving in [first_serving, second_serving, honest_serving] {
            within(DEADLINE, serving).await.unwrap().unwrap();
        }
    }

    #[tokio::test]
    async fn a_session_cut_while_its_reads_wait_for_a_place_ends_at_once() {
        let site = sharing_places();
        // Two other sessions take every place between them.
        let (mut first, first_serving) = hello(&site).await;
        let (mut second, second_serving) = hello(&site).await;
        send_reads(&mut first, "big", WINDOW).await;
        assert_eq!(until_quiet(&mut first).await.0.len(), WINDOW);
        send_reads(&mut second, "big", PLACES - WINDOW).await;
        assert_eq!(until_quiet(&mut second).await.0.len(), PLACES - WINDOW);

        let (fire, until) = cut();
        let (mut waiting, waiting_serving) = site
            .serve_over(64 * 1024, None, until, |replica| replica)
            .await;
        assert!(matches!(
            waiting.ask(&Request::Hello(site.spec())).await,
            Ok(Reply::Hello(_))
        ));
        send_reads(&mut waiting, "small", WINDOW).await;
        assert_eq!(until_quiet(&mut waiting).await, (vec![], vec![]));

        // Its reads stop waiting with it, though every place is still
        // taken by the others.
        fire.send(()).unwrap();
        within(DEADLINE, waiting_serving).await.unwrap().unwrap();

        drop((first, second));
        for serving in [first_serving, second_serving] {
            within(DEADLINE, serving).await.unwrap().unwrap();
        }
    }

    #[tokio::test(start_paused = true)]
    async fn a_silent_client_is_reaped_after_the_silence_limit() {
        let site = Site::new();
        let (_client, serving) = site.serve(Some(Liveness::of(&Tuning::DEFAULT))).await;
        let started = tokio::time::Instant::now();
        let served = within(Duration::from_secs(300), serving).await.unwrap();
        assert!(
            matches!(served, Err(LinkError::PeerSilent { .. })),
            "{served:?}"
        );
        assert_eq!(started.elapsed(), Duration::from_secs(30));
    }

    /// A link small enough that a read body fills it, and the outbox
    /// behind it, long before the body ends.
    const NARROW_LINK: usize = 4 * 1024;

    /// A locked session whose client opened a read of `big`, granted it
    /// all, and then reads nothing more: the server's writer is stuck
    /// behind a full link and the read's handler behind a full outbox.
    async fn stuck_mid_read(
        liveness: Option<Liveness>,
        until: impl Future<Output = ()> + Send + 'static,
    ) -> (Site, Client, JoinHandle<Result<(), LinkError>>) {
        let site = Site::new();
        fs::write(site.dir.path().join("root/big"), vec![7u8; BIG]).unwrap();
        let (mut client, serving) = site
            .serve_over(NARROW_LINK, liveness, until, |replica| replica)
            .await;
        assert!(matches!(
            client.ask(&Request::Hello(site.spec())).await,
            Ok(Reply::Hello(_))
        ));
        assert!(matches!(
            client.ask(&Request::Lock).await,
            Ok(Reply::Locked(_))
        ));
        let id = client.open_read("big").await;
        let grant = crate::credit::grant_frame(id, BIG);
        client.send_to(Kind::Credit, id, grant.payload).await;
        (site, client, serving)
    }

    /// A future ready once its sender fires.
    fn cut() -> (
        oneshot::Sender<()>,
        impl Future<Output = ()> + Send + 'static,
    ) {
        let (fire, fired) = oneshot::channel::<()>();
        (fire, async move {
            let _ = fired.await;
        })
    }

    #[tokio::test]
    async fn a_client_gone_silent_mid_read_frees_the_lock_after_the_silence_limit() {
        let liveness = Liveness {
            heartbeat: Duration::from_millis(100),
            silence_limit: Duration::from_secs(1),
        };
        let (site, _client, serving) = stuck_mid_read(Some(liveness), std::future::pending()).await;
        assert!(!site.lock_is_free());
        let served = within(liveness.silence_limit + Duration::from_secs(2), serving)
            .await
            .unwrap();
        assert!(
            matches!(served, Err(LinkError::PeerSilent { .. })),
            "{served:?}"
        );
        assert!(site.lock_is_free());
    }

    #[tokio::test]
    async fn a_session_cut_mid_read_frees_the_lock_at_once() {
        let (fire, until) = cut();
        let (site, _client, serving) = stuck_mid_read(None, until).await;
        // Long enough for the body to fill the link and the outbox.
        tokio::time::sleep(Duration::from_millis(200)).await;
        assert!(!site.lock_is_free());
        fire.send(()).unwrap();
        within(DEADLINE, serving).await.unwrap().unwrap();
        assert!(site.lock_is_free());
    }

    /// A write `path` of `bytes`, sent as its request and one chunk and
    /// never ended: its id.
    async fn send_unended_write(client: &mut Client, path: &str, bytes: usize) -> u32 {
        let request = Request::Write {
            path: RelPath::parse(path).unwrap(),
            source: FileState {
                meta: FileMeta {
                    size: 2 * bytes as u64,
                    mtime_us: 0,
                    mode: 0o644,
                    read_us: 0,
                },
                hash: ContentHash::from_digest([0; 32]),
            },
            expect: Precondition::Absent,
        };
        let id = client.send_raw(Kind::Request, wire::encode(&request)).await;
        client.send_to(Kind::Chunk, id, vec![1u8; bytes]).await;
        id
    }

    #[tokio::test]
    async fn a_cut_session_keeps_the_lock_until_a_held_write_is_let_go() {
        let gate = Arc::new(Semaphore::new(0));
        let entered = Arc::new(Notify::new());
        let (fire, until) = cut();
        let site = Site::new();
        let (mut client, mut serving) = {
            let (gate, entered) = (gate.clone(), entered.clone());
            site.serve_over(64 * 1024, None, until, move |inner| Gated {
                inner,
                gate: gate.clone(),
                entered: entered.clone(),
            })
            .await
        };
        assert!(matches!(
            client.ask(&Request::Hello(site.spec())).await,
            Ok(Reply::Hello(_))
        ));
        assert!(matches!(
            client.ask(&Request::Lock).await,
            Ok(Reply::Locked(_))
        ));
        send_unended_write(&mut client, "new", 1024).await;
        within(DEADLINE, entered.notified()).await;

        fire.send(()).unwrap();
        let early = tokio::time::timeout(Duration::from_millis(300), &mut serving).await;
        assert!(early.is_err(), "the session ended under a held write");
        assert!(!site.lock_is_free());

        gate.add_permits(1);
        within(DEADLINE, serving).await.unwrap().unwrap();
        assert!(site.lock_is_free());
    }

    #[tokio::test]
    async fn a_write_cut_with_its_session_leaves_no_temp() {
        let (fire, until) = cut();
        let site = Site::new();
        let (mut client, serving) = site
            .serve_over(64 * 1024, None, until, |replica| replica)
            .await;
        assert!(matches!(
            client.ask(&Request::Hello(site.spec())).await,
            Ok(Reply::Hello(_))
        ));
        assert!(matches!(
            client.ask(&Request::Lock).await,
            Ok(Reply::Locked(_))
        ));
        send_unended_write(&mut client, "new", 32 * 1024).await;
        within(DEADLINE, async {
            while site.staged().is_empty() {
                tokio::time::sleep(Duration::from_millis(10)).await;
            }
        })
        .await;

        fire.send(()).unwrap();
        within(DEADLINE, serving).await.unwrap().unwrap();
        assert_eq!(site.staged(), Vec::<std::path::PathBuf>::new());
        assert!(!site.dir.path().join("root/new").exists());
    }

    /// A local replica whose writes each wait for a permit of `gate`
    /// before they start, saying on `entered` that one is waiting.
    struct Gated {
        inner: LocalReplica,
        gate: Arc<Semaphore>,
        entered: Arc<Notify>,
    }

    impl Replica for Gated {
        async fn hello(&self) -> Result<RootFacts, ReplicaError> {
            self.inner.hello().await
        }

        async fn lock(&self) -> Result<ArchiveFacts, ReplicaError> {
            self.inner.lock().await
        }

        async fn unlock(&self) -> Result<(), ReplicaError> {
            self.inner.unlock().await
        }

        async fn create_root(&self) -> Result<(), ReplicaError> {
            self.inner.create_root().await
        }

        async fn open_scan(&self, rules: &RuleSet) -> Result<OpenedScan, ReplicaError> {
            self.inner.open_scan(rules).await
        }

        async fn scan_digests(
            &self,
            ticket: DigestTicket,
            count: BucketCount,
            peer_changed: &[RelPath],
        ) -> Result<DigestedScan, ReplicaError> {
            self.inner.scan_digests(ticket, count, peer_changed).await
        }

        async fn scan_buckets(
            &self,
            ticket: &BucketTicket,
            buckets: &[Bucket],
        ) -> Result<Vec<ScanEntry>, ReplicaError> {
            self.inner.scan_buckets(ticket, buckets).await
        }

        async fn read(&self, path: &RelPath) -> Result<Reading, ReplicaError> {
            self.inner.read(path).await
        }

        async fn write(
            &self,
            path: &RelPath,
            body: Body,
            source: FileState,
            expect: Precondition,
        ) -> Result<FileMeta, ReplicaError> {
            self.entered.notify_one();
            let _permit = self.gate.acquire().await;
            self.inner.write(path, body, source, expect).await
        }

        async fn delete(&self, path: &RelPath, expect: Precondition) -> Result<(), ReplicaError> {
            self.inner.delete(path, expect).await
        }

        async fn remove_empty_dirs(&self, path: &RelPath) -> Result<(), ReplicaError> {
            self.inner.remove_empty_dirs(path).await
        }

        async fn commit(&self, batch: Vec<ArchiveCommit>) -> Result<(), ReplicaError> {
            self.inner.commit(batch).await
        }

        async fn compact(&self) -> Result<(), ReplicaError> {
            self.inner.compact().await
        }

        async fn close(self) -> Result<(), ReplicaError> {
            self.inner.close().await
        }

        fn write_stats(&self) -> Option<WriteStats> {
            Replica::write_stats(&self.inner)
        }
    }
}
