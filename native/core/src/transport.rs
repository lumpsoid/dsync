//! What a replica connection runs over: any `AsyncRead` + `AsyncWrite`
//! pair (plan D5) - an ssh child's stdout and stdin, this process's own
//! stdin and stdout, a unix stream, a TLS stream - plus, for network
//! transports only, a liveness bound.
//!
//! No transport class hierarchy: a transport is its two halves.

use std::future::Future;
use std::io;
use std::pin::Pin;
use std::task::{Context, Poll, ready};
use std::time::Duration;

use dsync_domain::Tuning;
use tokio::io::{AsyncRead, AsyncWrite, AsyncWriteExt, BufWriter, ReadBuf, ReadHalf, WriteHalf};
use tokio::sync::mpsc;
use tokio::task::{JoinError, JoinHandle};
use tokio::time::{Instant, Sleep};

use crate::credit::Credit;
use crate::frame::{Frame, Kind};
use crate::replica::Reading;
use crate::wire::{self, WireIo};

/// Bytes the frame reader buffers from the transport.
pub(crate) const READ_BUFFER_BYTES: usize = 64 * 1024;

/// Frames queued for the writer before a sender waits.
const OUTBOX_FRAMES: usize = 16;

/// A connection's two halves, and whether it bounds the far side's silence.
pub struct Transport<R, W> {
    pub(crate) reader: R,
    pub(crate) writer: W,
    pub(crate) liveness: Option<Liveness>,
}

/// SPEC §4.2's liveness bound for network transports (peer://): send a
/// heartbeat whenever this side has sent nothing for `heartbeat`, and fail
/// the connection when nothing at all - not even a heartbeat - arrives for
/// `silence_limit` while this side is reading.
///
/// Not for stdio or unix transports, on purpose: a dead unix peer is a
/// process on this machine whose socket the kernel closes, and ssh watches
/// its own connection (`ServerAliveInterval`). Between two dsync processes
/// on a raw network socket nobody does, and a sleeping laptop or an
/// expired NAT flow would otherwise leave a run waiting forever.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub struct Liveness {
    pub heartbeat: Duration,
    pub silence_limit: Duration,
}

impl Liveness {
    pub fn of(tuning: &Tuning) -> Liveness {
        Liveness {
            heartbeat: tuning.heartbeat,
            silence_limit: tuning.silence_limit,
        }
    }
}

impl<R, W> Transport<R, W>
where
    R: AsyncRead + Unpin + Send + 'static,
    W: AsyncWrite + Unpin + Send + 'static,
{
    pub fn new(reader: R, writer: W) -> Transport<R, W> {
        Transport {
            reader,
            writer,
            liveness: None,
        }
    }

    /// Bounds the far side's silence and sends heartbeats: for network
    /// transports only (see [`Liveness`]).
    pub fn with_liveness(self, liveness: Liveness) -> Transport<R, W> {
        Transport {
            liveness: Some(liveness),
            ..self
        }
    }
}

impl<S> Transport<ReadHalf<S>, WriteHalf<S>>
where
    S: AsyncRead + AsyncWrite + Unpin + Send + 'static,
{
    /// A transport over one bidirectional stream (a socket, a TLS stream).
    pub fn split(stream: S) -> Transport<ReadHalf<S>, WriteHalf<S>> {
        let (reader, writer) = tokio::io::split(stream);
        Transport::new(reader, writer)
    }
}

/// What the writer task is asked to do.
pub(crate) enum Out {
    Frame(Frame),
    /// Flush, shut the write half down and stop: the orderly close.
    Close,
}

/// The one way frames reach the transport: a queue in front of the task
/// that writes them, so frames from concurrent operations never interleave
/// on the wire.
#[derive(Clone)]
pub(crate) struct Outbox {
    frames: mpsc::Sender<Out>,
    /// The most body bytes one frame carries, so one large chunk does not
    /// hold the wire while other exchanges wait behind it.
    chunk_bytes: usize,
}

/// The writer task is gone: the connection failed or closed.
#[derive(Debug)]
pub(crate) struct OutboxClosed;

impl Outbox {
    pub async fn send(&self, frame: Frame) -> Result<(), OutboxClosed> {
        self.frames
            .send(Out::Frame(frame))
            .await
            .map_err(|_| OutboxClosed)
    }

    pub async fn close(&self) {
        let _ = self.frames.send(Out::Close).await;
    }

    /// Sends `bytes` as body frames of the exchange `id`, as `credit`
    /// allows.
    pub async fn send_chunk(
        &self,
        id: u32,
        mut bytes: Vec<u8>,
        credit: &Credit,
    ) -> Result<(), OutboxClosed> {
        let mut sent = 0;
        while sent < bytes.len() {
            let most = (bytes.len() - sent).min(self.chunk_bytes);
            let allowed = credit.take(most).await.ok_or(OutboxClosed)?;
            let piece = if allowed == bytes.len() {
                std::mem::take(&mut bytes)
            } else {
                bytes[sent..sent + allowed].to_vec()
            };
            self.send(Frame::new(Kind::Chunk, id, piece)).await?;
            sent += allowed;
        }
        Ok(())
    }

    /// Ends the body of exchange `id`: everything sent before is all of it.
    pub async fn end(&self, id: u32) -> Result<(), OutboxClosed> {
        self.send(Frame::new(Kind::End, id, Vec::new())).await
    }

    /// Ends the body of exchange `id` as failed, in place of its end.
    pub async fn fail(&self, id: u32, error: &io::Error) -> Result<(), OutboxClosed> {
        self.send(Frame::new(Kind::Fail, id, WireIo::encode_failure(error)))
            .await
    }

    /// Streams a read's body as exchange `id`'s frames, as `credit`
    /// allows, failing it as the body does. Its `End` carries what the
    /// file was once read (SPEC §7.6's source check).
    pub async fn send_read(
        &self,
        id: u32,
        reading: Reading,
        credit: Credit,
    ) -> Result<(), OutboxClosed> {
        let Reading { mut body, settled } = reading;
        loop {
            match body.next().await {
                Ok(Some(bytes)) => self.send_chunk(id, bytes, &credit).await?,
                Ok(None) => {
                    let now = settled.after().await;
                    return self
                        .send(Frame::new(Kind::End, id, wire::encode(&now)))
                        .await;
                }
                Err(error) => return self.fail(id, &error.into()).await,
            }
        }
    }
}

/// Starts the task writing the outbox's frames to `writer`: flushed
/// whenever the queue runs dry, with a heartbeat after every `heartbeat`
/// of silence when one is given. Returns when the outbox is closed or
/// dropped, or the transport fails.
pub(crate) fn start_writer<W>(
    writer: W,
    heartbeat: Option<Duration>,
    chunk_bytes: usize,
) -> (Outbox, Task<io::Result<()>>)
where
    W: AsyncWrite + Unpin + Send + 'static,
{
    let (frames, queue) = mpsc::channel(OUTBOX_FRAMES);
    let task = Task::spawn(write_frames(BufWriter::new(writer), queue, heartbeat));
    let outbox = Outbox {
        frames,
        chunk_bytes: chunk_bytes.max(1),
    };
    (outbox, task)
}

async fn write_frames<W: AsyncWrite + Unpin>(
    mut writer: BufWriter<W>,
    mut queue: mpsc::Receiver<Out>,
    heartbeat: Option<Duration>,
) -> io::Result<()> {
    loop {
        let next = match heartbeat {
            None => queue.recv().await,
            Some(every) => match tokio::time::timeout(every, queue.recv()).await {
                Ok(next) => next,
                Err(_) => Some(Out::Frame(Frame::heartbeat())),
            },
        };
        match next {
            Some(Out::Frame(frame)) => {
                frame.write_to(&mut writer).await?;
                if queue.is_empty() {
                    writer.flush().await?;
                }
            }
            Some(Out::Close) | None => {
                writer.flush().await?;
                return writer.shutdown().await;
            }
        }
    }
}

/// A spawned task that is stopped when its handle is dropped, so a
/// connection's reader and writer never outlive whoever runs the
/// connection.
pub(crate) struct Task<T>(JoinHandle<T>);

impl<T: Send + 'static> Task<T> {
    pub fn spawn(work: impl Future<Output = T> + Send + 'static) -> Task<T> {
        Task(tokio::spawn(work))
    }

    pub fn abort(&self) {
        self.0.abort();
    }
}

impl<T> Future for Task<T> {
    type Output = Result<T, JoinError>;

    fn poll(mut self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<Self::Output> {
        Pin::new(&mut self.0).poll(cx)
    }
}

impl<T> Drop for Task<T> {
    fn drop(&mut self) {
        self.0.abort();
    }
}

/// A reader that fails with [`io::ErrorKind::TimedOut`] once it has waited
/// `limit` for bytes without any arriving.
///
/// Armed only while someone is reading: the time between one read
/// returning and the next starting - this side busy handing a request
/// on - is this side's, and counting it would reap a healthy peer for
/// this side's own work.
pub(crate) struct SilenceLimit<R> {
    inner: R,
    limit: Option<Duration>,
    deadline: Pin<Box<Sleep>>,
    waiting: bool,
}

impl<R> SilenceLimit<R> {
    pub fn new(inner: R, limit: Option<Duration>) -> SilenceLimit<R> {
        SilenceLimit {
            inner,
            limit,
            deadline: Box::pin(tokio::time::sleep_until(Instant::now())),
            waiting: false,
        }
    }
}

impl<R: AsyncRead + Unpin> AsyncRead for SilenceLimit<R> {
    fn poll_read(
        mut self: Pin<&mut Self>,
        cx: &mut Context<'_>,
        buf: &mut ReadBuf<'_>,
    ) -> Poll<io::Result<()>> {
        let this = &mut *self;
        if let Poll::Ready(result) = Pin::new(&mut this.inner).poll_read(cx, buf) {
            this.waiting = false;
            return Poll::Ready(result);
        }
        let Some(limit) = this.limit else {
            return Poll::Pending;
        };
        if !this.waiting {
            this.waiting = true;
            this.deadline.as_mut().reset(Instant::now() + limit);
        }
        ready!(this.deadline.as_mut().poll(cx));
        Poll::Ready(Err(io::Error::new(
            io::ErrorKind::TimedOut,
            format!("nothing arrived for {limit:?}"),
        )))
    }
}
