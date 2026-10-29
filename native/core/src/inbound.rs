//! Routing a body arriving over a connection to whoever consumes it,
//! without letting one slow consumer stall the connection (SPEC §4.2).
//!
//! **Every frame is taken off the transport the moment it is decoded, and
//! the reader never waits on a body.** A body whose consumer is not taking
//! its chunks - a served write still waiting for a writer, a read admitted
//! ahead of a worker - keeps them queued, in order, while every other
//! exchange carries on past it. What bounds the queue is its sender's
//! credit ([`crate::credit`]): the sender puts no more than
//! [`STREAM_CREDIT_BYTES`] on the wire ahead of what the consumer has
//! taken, and this end grants credit back as it takes. A chunk past the
//! credit is the far side breaking the protocol.
//!
//! A read body its consumer drops tells its sender to stop with a `Cancel`
//! frame, and holds its guard - the read's window slot -
//! until the sender's terminating frame: the far end has the file open
//! until then, so no write on that path may start under it. That is safe
//! only because a sender always ends a cancelled body with a frame.

use std::sync::Arc;
use std::sync::atomic::{AtomicUsize, Ordering};

use tokio::sync::mpsc;

use crate::body::{Body, BodySender, body_channel};
use crate::credit::{GRANT_BYTES, STREAM_CREDIT_BYTES, grant_frame};
use crate::frame::{Frame, Kind};
use crate::transport::Outbox;
use crate::wire::WireIo;

/// Chunks a routed body holds ready for its consumer, beyond its queue.
const BODY_CHUNKS: usize = 2;

/// One piece of a routed body.
pub(crate) enum Piece {
    Chunk(Vec<u8>),
    End,
    Fail(WireIo),
}

/// What a routed body does once its consumer has gone away; either way the
/// rest of the body is drained, still granting credit, so its sender is
/// never left waiting on a grant.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub(crate) enum Dropped {
    /// Releases the guard at once and lets the sender run to its end: a
    /// served write's body.
    Release,
    /// Sends `Cancel` once and holds the guard until the sender's
    /// terminating frame: a read.
    Cancel,
}

/// A chunk past the credit its sender was given.
#[derive(Debug)]
pub(crate) struct Overrun;

/// The reader's end of one body being routed: pieces go in without ever
/// waiting, and a task feeds them to the body's consumer.
pub(crate) struct Inbound {
    pieces: mpsc::UnboundedSender<Piece>,
    /// Bytes the sender may still send.
    credit: Arc<AtomicUsize>,
}

impl Inbound {
    /// The body of exchange `id` and the route feeding it, granting credit
    /// back on `outbox`. `guard` is held until the body is over - ended,
    /// failed, or dropped by its consumer as `dropped` says: a read's
    /// window slot lives here.
    pub fn open(
        outbox: Outbox,
        id: u32,
        guard: impl Send + 'static,
        dropped: Dropped,
    ) -> (Inbound, Body) {
        let (sender, body) = body_channel(BODY_CHUNKS);
        let (pieces, queue) = mpsc::unbounded_channel();
        let credit = Arc::new(AtomicUsize::new(STREAM_CREDIT_BYTES));
        let granting = Granting {
            outbox,
            id,
            credit: credit.clone(),
            taken: 0,
        };
        tokio::spawn(feed(queue, sender, granting, guard, dropped));
        (Inbound { pieces, credit }, body)
    }

    /// Queues `piece` for the consumer; never waits. Whether the body is
    /// over with it.
    pub fn push(&self, piece: Piece) -> Result<bool, Overrun> {
        if let Piece::Chunk(bytes) = &piece {
            self.credit
                .fetch_update(Ordering::AcqRel, Ordering::Acquire, |left| {
                    left.checked_sub(bytes.len())
                })
                .map_err(|_| Overrun)?;
        }
        let over = !matches!(piece, Piece::Chunk(_));
        // A consumer gone and drained: the piece has nowhere to go.
        let _ = self.pieces.send(piece);
        Ok(over)
    }
}

/// Grants a body's sender credit for what its consumer has taken, once
/// there is [`GRANT_BYTES`] of it.
struct Granting {
    outbox: Outbox,
    id: u32,
    credit: Arc<AtomicUsize>,
    taken: usize,
}

impl Granting {
    async fn took(&mut self, bytes: usize) {
        self.taken += bytes;
        if self.taken < GRANT_BYTES {
            return;
        }
        // Counted before it is sent, so the chunks it lets through are
        // never read as past the credit.
        self.credit.fetch_add(self.taken, Ordering::AcqRel);
        let _ = self.outbox.send(grant_frame(self.id, self.taken)).await;
        self.taken = 0;
    }
}

/// Hands `queue`'s pieces to the body, granting credit as the consumer
/// takes each chunk. A consumer that goes away leaves the rest of the body
/// to be drained, as `dropped` says; a queue closed without an end (the
/// connection dropped) drops the sender, which the consumer reads as
/// [`crate::BodyError::CutShort`], and the guard.
async fn feed(
    mut queue: mpsc::UnboundedReceiver<Piece>,
    sender: BodySender,
    mut granting: Granting,
    guard: impl Send,
    dropped: Dropped,
) {
    while let Some(piece) = queue.recv().await {
        match piece {
            Piece::Chunk(bytes) => {
                let taken = bytes.len();
                let delivered = sender.send(bytes).await;
                granting.took(taken).await;
                if delivered.is_err() {
                    match dropped {
                        Dropped::Release => {
                            drop(guard);
                            drain(queue, granting).await;
                        }
                        Dropped::Cancel => {
                            let cancel = Frame::new(Kind::Cancel, granting.id, Vec::new());
                            let _ = granting.outbox.send(cancel).await;
                            drain(queue, granting).await;
                            drop(guard);
                        }
                    }
                    return;
                }
            }
            Piece::End => {
                let _ = sender.finish().await;
                return;
            }
            Piece::Fail(error) => {
                let _ = sender.fail(error.into()).await;
                return;
            }
        }
    }
}

async fn drain(mut queue: mpsc::UnboundedReceiver<Piece>, mut granting: Granting) {
    while let Some(piece) = queue.recv().await {
        match piece {
            Piece::Chunk(bytes) => granting.took(bytes.len()).await,
            Piece::End | Piece::Fail(_) => return,
        }
    }
}

#[cfg(test)]
mod tests {
    use std::time::Duration;

    use tokio::io::{BufReader, DuplexStream, duplex};
    use tokio::sync::oneshot;

    use super::*;
    use crate::transport::{Task, start_writer};

    const DEADLINE: Duration = Duration::from_secs(5);

    /// A route over a fresh outbox, with a receiver that sees its guard
    /// go and the far end of the outbox's wire.
    struct Routed {
        inbound: Inbound,
        body: Body,
        held: oneshot::Receiver<()>,
        wire: BufReader<DuplexStream>,
        _writing: Task<std::io::Result<()>>,
    }

    fn routed(dropped: Dropped) -> Routed {
        let (near, far) = duplex(64 * 1024);
        let (outbox, writing) = start_writer(near, None, 64 * 1024);
        let (guard, held) = oneshot::channel::<()>();
        let (inbound, body) = Inbound::open(outbox, 7, guard, dropped);
        Routed {
            inbound,
            body,
            held,
            wire: BufReader::new(far),
            _writing: writing,
        }
    }

    async fn next_frame(wire: &mut BufReader<DuplexStream>) -> Option<Frame> {
        tokio::time::timeout(Duration::from_millis(100), Frame::read_from(wire))
            .await
            .ok()
            // The wire closing - every outbox gone - is no frame either.
            .and_then(|frame| frame.unwrap())
    }

    /// Whether the guard is gone within the deadline.
    async fn released(held: &mut oneshot::Receiver<()>) -> bool {
        tokio::time::timeout(DEADLINE, held).await.is_ok()
    }

    fn still_held(held: &mut oneshot::Receiver<()>) -> bool {
        matches!(held.try_recv(), Err(oneshot::error::TryRecvError::Empty))
    }

    #[tokio::test]
    async fn a_read_its_consumer_drops_cancels_once_and_holds_its_guard_to_the_end() {
        let Routed {
            inbound,
            body,
            mut held,
            mut wire,
            _writing,
        } = routed(Dropped::Cancel);
        drop(body);
        for _ in 0..3 {
            assert!(!inbound.push(Piece::Chunk(vec![1; 10])).unwrap());
        }
        let cancel = next_frame(&mut wire).await.expect("a cancel was sent");
        assert_eq!((cancel.kind, cancel.id), (Kind::Cancel, 7));
        assert!(cancel.payload.is_empty());
        assert_eq!(next_frame(&mut wire).await, None, "a second cancel");
        assert!(
            still_held(&mut held),
            "released before the terminating frame"
        );

        assert!(
            inbound
                .push(Piece::Fail(WireIo::from(&std::io::Error::other("x"))))
                .unwrap()
        );
        assert!(released(&mut held).await);
        assert_eq!(next_frame(&mut wire).await, None);
    }

    #[tokio::test]
    async fn a_write_its_consumer_drops_sends_nothing_and_releases_at_once() {
        let Routed {
            inbound,
            body,
            mut held,
            mut wire,
            _writing,
        } = routed(Dropped::Release);
        drop(body);
        assert!(!inbound.push(Piece::Chunk(vec![1; 10])).unwrap());
        assert!(released(&mut held).await, "held until the end");
        assert_eq!(next_frame(&mut wire).await, None, "a frame was sent");
        assert!(inbound.push(Piece::End).unwrap());
    }
}
