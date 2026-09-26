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

use dsync_domain::{Bucket, BucketCount, ReplicaSpec, Tuning};
use tokio::io::{AsyncRead, AsyncWrite, BufReader};
use tokio::sync::mpsc;
use tokio::task::JoinSet;

use crate::body::Body;
use crate::credit::{self, Credits};
use crate::frame::{Frame, FrameError, Kind};
use crate::inbound::{Inbound, Piece};
use crate::link_error::LinkError;
use crate::remote_replica::silent_if_timed_out;
use crate::replica::{BucketTicket, DigestTicket, Replica};
use crate::replica_error::ReplicaError;
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
pub struct ReplicaServer<F> {
    open: F,
    tuning: Tuning,
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
    pub fn new(open: F, tuning: Tuning) -> ReplicaServer<F> {
        ReplicaServer { open, tuning }
    }

    /// Serves one session over `transport` until the client closes it (or
    /// it fails, or the prologue is refused). The session's replica, and
    /// any lock it holds, is released before this returns.
    pub async fn serve<Rd, Wr>(&self, transport: Transport<Rd, Wr>) -> Result<(), LinkError>
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
        // Bounded by the client's window in practice; the bound here only
        // keeps a flooding client from queueing without limit.
        let (arrived, incoming) = mpsc::channel(self.tuning.request_window.max(1));
        let credits = Credits::new();
        let mut reading = Task::spawn(read_requests(
            reader,
            arrived,
            outbox.clone(),
            credits.clone(),
            liveness,
        ));
        self.session(incoming, &outbox, &credits).await;
        // A session the prologue refused stops reading here; one the client
        // closed has stopped already.
        reading.abort();
        let read = (&mut reading).await.unwrap_or(Ok(()));
        outbox.close().await;
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
        let opening = (self.open)(spec);
        tokio::pin!(opening);
        let opened = tokio::select! {
            opened = &mut opening => opened,
            // A peer that sends past the prologue without waiting for its
            // answer is one whose later requests cannot safely be guessed
            // at: the session ends.
            _ = incoming.recv() => return,
        };
        let replica = match opened {
            Ok(replica) => replica,
            Err(error) => return reply(outbox, first.id, Err(error.into())).await,
        };
        let served = Arc::new(Served {
            replica,
            scan: Mutex::new(ServedScan::Closed),
            outbox: outbox.clone(),
            credits: credits.clone(),
        });
        let hello = served.replica.hello().await.map(Reply::Hello);
        reply(outbox, first.id, hello.map_err(WireError::from)).await;
        let mut running = JoinSet::new();
        while let Some(next) = incoming.recv().await {
            running.spawn(served.clone().handle(next));
            while running.try_join_next().is_some() {}
        }
        while running.join_next().await.is_some() {}
        // `served` - the replica, its lock and its archive - goes here.
    }
}

impl<F> ReplicaServer<F> {
    /// Serves one session over this process's own stdin and stdout: the
    /// far end of an ssh transport (`dsync agent --stdio`).
    pub async fn serve_stdio<Opening, R>(&self) -> Result<(), LinkError>
    where
        F: Fn(ReplicaSpec) -> Opening + Send + Sync,
        Opening: Future<Output = Result<R, ReplicaError>> + Send,
        R: Replica + 'static,
    {
        self.serve(Transport::new(tokio::io::stdin(), tokio::io::stdout()))
            .await
    }
}

/// A session's replica, where its scan exchange stands, and the credit
/// of the read bodies it is sending.
struct Served<R> {
    replica: R,
    scan: Mutex<ServedScan>,
    outbox: Outbox,
    credits: Arc<Credits>,
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
            Request::Lock => replica.lock().await.map(|()| Reply::Done),
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
                    return reply(&self.outbox, id, Err(protocol("a bucket count of 0"))).await;
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
            Request::Read(path) => match replica.read(&path).await {
                Ok(reading) => {
                    // Open before the reply, so no grant can arrive ahead
                    // of it.
                    let credit = self.credits.open(id);
                    reply(&self.outbox, id, Ok(Reply::Opened)).await;
                    // Forwarded as it is read: a local read holds a blocking
                    // thread until its body is consumed.
                    let _ = self.outbox.send_read(id, reading, credit).await;
                    return;
                }
                Err(error) => Err(error),
            },
            Request::Write { path, meta, expect } => match body {
                Some(body) => replica
                    .write(&path, body, meta, expect)
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

/// The reader: requests to the session, a write's body frames to its
/// body, grants to the read bodies being sent. Returns `Ok` when the
/// client closes its end; either way every read body still being sent
/// stops.
async fn read_requests<R: AsyncRead + Unpin>(
    reader: BufReader<SilenceLimit<R>>,
    arrived: mpsc::Sender<Incoming>,
    outbox: Outbox,
    credits: Arc<Credits>,
    liveness: Option<Liveness>,
) -> Result<(), LinkError> {
    let read = route_requests(reader, arrived, outbox, &credits, liveness).await;
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
            Kind::Request => {
                let request = wire::decode::<Request>(&frame.payload);
                // The body's route opens before the next frame is read, so
                // none of the body can arrive ahead of it.
                let body = matches!(request, Ok(Request::Write { .. })).then(|| {
                    let (inbound, body) = Inbound::open(outbox.clone(), frame.id, ());
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

    use dsync_domain::{EntryId, Jobs, Precondition, RelPath, Side};
    use tokio::io::{AsyncWriteExt, DuplexStream, ReadHalf, WriteHalf, duplex};
    use tokio::task::JoinHandle;

    use super::*;
    use crate::local_replica::LocalReplica;
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
    }

    impl Site {
        fn new() -> Site {
            let dir = tempfile::tempdir().unwrap();
            fs::create_dir(dir.path().join("root")).unwrap();
            Site { dir }
        }

        fn spec(&self) -> ReplicaSpec {
            ReplicaSpec {
                root: self.dir.path().join("root").to_str().unwrap().to_owned(),
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
            let state = StateDir::new(self.dir.path().join("state"));
            let server = ReplicaServer::new(
                move |spec: ReplicaSpec| {
                    let state = state.clone();
                    async move {
                        let opened = tokio::task::spawn_blocking(move || {
                            LocalReplica::open(
                                spec.root,
                                state,
                                spec.entry,
                                spec.side,
                                spec.jobs,
                                Tuning::DEFAULT,
                                crate::Symlinks::AsRuled,
                            )
                        });
                        Ok(opened.await.unwrap()?)
                    }
                },
                Tuning::DEFAULT,
            );
            let (near, far) = duplex(64 * 1024);
            let transport = Transport::split(near);
            let transport = match liveness {
                Some(liveness) => transport.with_liveness(liveness),
                None => transport,
            };
            let serving = tokio::spawn(async move { server.serve(transport).await });
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
}
