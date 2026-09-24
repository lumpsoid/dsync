//! A file's bytes in flight, from whoever produces them (a local read, a
//! connection) to whoever consumes them (a write, a connection).
//!
//! One type both ways, so a copy between two replicas plugs one side's
//! [`crate::Replica::read`] straight into the other's
//! [`crate::Replica::write`].
//!
//! The end is explicit: a body is whole only once its sender calls
//! [`BodySender::finish`]. A sender dropped without finishing - a read
//! task that panicked, a connection that went away, a write future that
//! was cancelled - reads as [`BodyError::CutShort`], never as a short file,
//! so a torn transfer can never be committed as a complete one (SPEC §7.6).

use std::io;

use tokio::sync::mpsc;

/// What [`Body::from_bytes`] queues: the bytes and the end.
const WHOLE_BODY_PIECES: usize = 2;

enum Piece {
    Bytes(Vec<u8>),
    End,
    Failed(io::Error),
}

/// A body whose bytes are still arriving. Chunks come in the order they
/// were sent.
pub struct Body {
    pieces: mpsc::Receiver<Piece>,
    finished: bool,
}

/// The producing end of a [`Body`]. Sending waits while `capacity` chunks
/// are unconsumed, so a slow consumer paces the producer.
pub struct BodySender {
    pieces: mpsc::Sender<Piece>,
}

/// Why a body did not arrive whole.
#[derive(Debug, thiserror::Error)]
pub enum BodyError {
    /// The producer reported a failure: the read, or the far side's read,
    /// failed part-way.
    #[error("the body failed at its source: {0}")]
    Failed(#[source] io::Error),
    /// The producer went away without finishing the body.
    #[error("the body was cut short")]
    CutShort,
}

impl From<BodyError> for io::Error {
    fn from(error: BodyError) -> io::Error {
        match error {
            BodyError::Failed(source) => source,
            BodyError::CutShort => io::Error::new(io::ErrorKind::UnexpectedEof, error),
        }
    }
}

/// The consumer of a body stopped taking it; there is nobody left to send
/// to.
#[derive(Debug, thiserror::Error)]
#[error("the body's consumer went away")]
pub struct BodyDropped;

/// A body and its sender, buffering at most `capacity` chunks between
/// them.
pub fn body_channel(capacity: usize) -> (BodySender, Body) {
    let (pieces_tx, pieces) = mpsc::channel(capacity);
    (
        BodySender { pieces: pieces_tx },
        Body {
            pieces,
            finished: false,
        },
    )
}

impl Body {
    /// A body already whole: `bytes` and its end.
    pub fn from_bytes(bytes: Vec<u8>) -> Body {
        let (sender, body) = body_channel(WHOLE_BODY_PIECES);
        if !bytes.is_empty() {
            let _ = sender.pieces.try_send(Piece::Bytes(bytes));
        }
        let _ = sender.pieces.try_send(Piece::End);
        body
    }

    /// The next chunk; `Ok(None)` once the sender has finished the body.
    pub async fn next(&mut self) -> Result<Option<Vec<u8>>, BodyError> {
        if self.finished {
            return Ok(None);
        }
        let piece = self.pieces.recv().await;
        self.take(piece)
    }

    /// Every remaining byte, once the body is finished.
    pub async fn collect(mut self) -> Result<Vec<u8>, BodyError> {
        let mut all = Vec::new();
        while let Some(chunk) = self.next().await? {
            all.extend_from_slice(&chunk);
        }
        Ok(all)
    }

    fn take(&mut self, piece: Option<Piece>) -> Result<Option<Vec<u8>>, BodyError> {
        match piece {
            Some(Piece::Bytes(bytes)) => Ok(Some(bytes)),
            Some(Piece::End) => {
                self.finished = true;
                Ok(None)
            }
            Some(Piece::Failed(error)) => Err(BodyError::Failed(error)),
            None => Err(BodyError::CutShort),
        }
    }
}

impl BodySender {
    /// Queues a chunk, waiting for room.
    pub async fn send(&self, bytes: Vec<u8>) -> Result<(), BodyDropped> {
        self.put(Piece::Bytes(bytes)).await
    }

    /// Marks the body whole.
    pub async fn finish(self) -> Result<(), BodyDropped> {
        self.put(Piece::End).await
    }

    /// Ends the body as failed, with why.
    pub async fn fail(self, error: io::Error) -> Result<(), BodyDropped> {
        self.put(Piece::Failed(error)).await
    }

    /// [`BodySender::send`] for a blocking thread.
    pub fn blocking_send(&self, bytes: Vec<u8>) -> Result<(), BodyDropped> {
        self.blocking_put(Piece::Bytes(bytes))
    }

    /// [`BodySender::finish`] for a blocking thread.
    pub fn blocking_finish(self) -> Result<(), BodyDropped> {
        self.blocking_put(Piece::End)
    }

    /// [`BodySender::fail`] for a blocking thread.
    pub fn blocking_fail(self, error: io::Error) -> Result<(), BodyDropped> {
        self.blocking_put(Piece::Failed(error))
    }

    async fn put(&self, piece: Piece) -> Result<(), BodyDropped> {
        self.pieces.send(piece).await.map_err(|_| BodyDropped)
    }

    fn blocking_put(&self, piece: Piece) -> Result<(), BodyDropped> {
        self.pieces.blocking_send(piece).map_err(|_| BodyDropped)
    }
}
