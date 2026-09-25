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

use std::sync::Arc;
use std::sync::atomic::{AtomicUsize, Ordering};

use tokio::sync::mpsc;

use crate::body::{Body, BodySender, body_channel};
use crate::credit::{GRANT_BYTES, STREAM_CREDIT_BYTES, grant_frame};
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
    /// failed, or dropped by its consumer: a read's window slot lives
    /// here.
    pub fn open(outbox: Outbox, id: u32, guard: impl Send + 'static) -> (Inbound, Body) {
        let (sender, body) = body_channel(BODY_CHUNKS);
        let (pieces, queue) = mpsc::unbounded_channel();
        let credit = Arc::new(AtomicUsize::new(STREAM_CREDIT_BYTES));
        let granting = Granting {
            outbox,
            id,
            credit: credit.clone(),
            taken: 0,
        };
        tokio::spawn(feed(queue, sender, granting, guard));
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
/// to be drained, still granting, so its sender runs to the end; a queue
/// closed without an end (the connection dropped) drops the sender, which
/// the consumer reads as [`crate::BodyError::CutShort`].
async fn feed(
    mut queue: mpsc::UnboundedReceiver<Piece>,
    sender: BodySender,
    mut granting: Granting,
    guard: impl Send,
) {
    while let Some(piece) = queue.recv().await {
        match piece {
            Piece::Chunk(bytes) => {
                let taken = bytes.len();
                let delivered = sender.send(bytes).await;
                granting.took(taken).await;
                if delivered.is_err() {
                    drop(guard);
                    drain(queue, granting).await;
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
