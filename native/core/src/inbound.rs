//! Routing a body arriving over a connection to whoever consumes it,
//! without letting one slow consumer stall the connection (SPEC §4.2).
//!
//! **Every frame is taken off the transport the moment it is decoded;
//! backpressure is a byte budget across the connection.** A body whose
//! consumer is not taking its chunks - a served write still opening its
//! file, a read whose destination is busy - keeps them queued, in order,
//! while every other exchange carries on past it. Bytes queued and not yet
//! taken are counted, and the reader stops reading while they exceed the
//! budget, until the consumers holding them take enough back.
//!
//! The budget cannot be shared out per route: a reader cannot know whose
//! frame is next until it has read it, so a per-route cap would mean
//! pausing the whole input on one route's account - the head-of-line block
//! this replaces. One route can hold all of it; what bounds that route is
//! its own consumer.

use std::sync::{Arc, Mutex, PoisonError};

use tokio::sync::{Notify, mpsc};

use crate::body::{Body, BodySender, body_channel};
use crate::wire::WireIo;

/// Chunks a routed body holds ready for its consumer, beyond its queue.
const BODY_CHUNKS: usize = 2;

/// Bytes routed to bodies and not yet taken by their consumers, against a
/// limit.
pub(crate) struct Budget {
    limit: usize,
    held: Mutex<usize>,
    freed: Notify,
}

impl Budget {
    pub fn new(limit: usize) -> Arc<Budget> {
        Arc::new(Budget {
            limit,
            held: Mutex::new(0),
            freed: Notify::new(),
        })
    }

    fn held(&self) -> std::sync::MutexGuard<'_, usize> {
        self.held.lock().unwrap_or_else(PoisonError::into_inner)
    }

    fn hold(&self, bytes: usize) {
        *self.held() += bytes;
    }

    fn release(&self, bytes: usize) {
        *self.held() -= bytes;
        self.freed.notify_waiters();
    }

    /// Returns once what is held is within the limit: the reader's gate
    /// before it reads the next frame.
    pub async fn within(&self) {
        loop {
            let freed = self.freed.notified();
            if *self.held() <= self.limit {
                return;
            }
            freed.await;
        }
    }
}

/// One piece of a routed body.
pub(crate) enum Piece {
    Chunk(Vec<u8>),
    End,
    Fail(WireIo),
}

/// The reader's end of one body being routed: pieces go in without ever
/// waiting, and a task feeds them to the body's consumer.
pub(crate) struct Inbound {
    pieces: mpsc::UnboundedSender<Piece>,
    budget: Arc<Budget>,
}

impl Inbound {
    /// A body and the route feeding it. `guard` is held until the body is
    /// over - ended, failed, or dropped by its consumer: a read's window
    /// slot lives here.
    pub fn open(budget: Arc<Budget>, guard: impl Send + 'static) -> (Inbound, Body) {
        let (sender, body) = body_channel(BODY_CHUNKS);
        let (pieces, queue) = mpsc::unbounded_channel();
        tokio::spawn(feed(queue, sender, budget.clone(), guard));
        (Inbound { pieces, budget }, body)
    }

    /// Queues `piece` for the consumer; never waits. Whether the body is
    /// over with it.
    pub fn push(&self, piece: Piece) -> bool {
        let over = !matches!(piece, Piece::Chunk(_));
        if let Piece::Chunk(bytes) = &piece {
            self.budget.hold(bytes.len());
        }
        if let Err(mpsc::error::SendError(Piece::Chunk(bytes))) = self.pieces.send(piece) {
            self.budget.release(bytes.len());
        }
        over
    }
}

/// Hands `queue`'s pieces to the body, giving each chunk's bytes back to
/// the budget as the consumer takes it. A consumer that goes away leaves
/// the rest of the body to be drained, still giving bytes back; a queue
/// closed without an end (the connection dropped) drops the sender, which
/// the consumer reads as [`crate::BodyError::CutShort`].
async fn feed(
    mut queue: mpsc::UnboundedReceiver<Piece>,
    sender: BodySender,
    budget: Arc<Budget>,
    guard: impl Send,
) {
    while let Some(piece) = queue.recv().await {
        match piece {
            Piece::Chunk(bytes) => {
                let taken = bytes.len();
                let delivered = sender.send(bytes).await;
                budget.release(taken);
                if delivered.is_err() {
                    drop(guard);
                    drain(queue, &budget).await;
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

async fn drain(mut queue: mpsc::UnboundedReceiver<Piece>, budget: &Budget) {
    while let Some(piece) = queue.recv().await {
        if let Piece::Chunk(bytes) = piece {
            budget.release(bytes.len());
        }
    }
}
