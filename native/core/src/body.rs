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
//!
//! A copy's body ends whole only once its source has also settled as the
//! scan saw it ([`crate::Reading::checked`]): a source that moved under its
//! read fails the body in place of its end, so the write it feeds drops its
//! temp instead of renaming it onto the destination's last good version.

use std::io;
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};

use dsync_domain::{OnDisk, Precondition};
use tokio::sync::{mpsc, oneshot};

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
    end: End,
}

/// How far a body has got to its end.
enum End {
    /// Its pieces are still arriving; the check, when there is one, decides
    /// whether their end makes the body whole.
    Open(Option<SettleCheck>),
    /// Its end arrived, and waits on the check.
    Settling(SettleCheck),
    Whole,
    SourceMoved,
}

/// A copy's source check (SPEC §7.6): what the file read was once its last
/// byte was read, against what the scan saw there.
struct SettleCheck {
    settled: oneshot::Receiver<OnDisk>,
    expect: Precondition,
    moved: SourceMoved,
}

/// Whether a body failed because its source moved under its read, for the
/// copy that handed the body on: once it crosses to a far writer, the
/// failure the write reports no longer says so.
#[derive(Clone, Default, Debug)]
pub struct SourceMoved(Arc<AtomicBool>);

impl SourceMoved {
    pub fn happened(&self) -> bool {
        self.0.load(Ordering::Acquire)
    }

    fn mark(&self) {
        self.0.store(true, Ordering::Release);
    }
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
    /// The file read was no longer what the scan saw once its last byte
    /// was read: the bytes may be another version, or a mix of two.
    #[error("the source changed while it was read")]
    SourceMoved,
}

impl From<BodyError> for io::Error {
    fn from(error: BodyError) -> io::Error {
        match error {
            BodyError::Failed(source) => source,
            BodyError::CutShort => io::Error::new(io::ErrorKind::UnexpectedEof, error),
            BodyError::SourceMoved => io::Error::other(error),
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
            end: End::Open(None),
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

    /// This body, ending whole only if its source settled as `expect` once
    /// read: `settled` is what the reader found then. Otherwise its end
    /// is [`BodyError::SourceMoved`], and the answer says so.
    pub(crate) fn settling(
        mut self,
        settled: oneshot::Receiver<OnDisk>,
        expect: Precondition,
    ) -> (Body, SourceMoved) {
        let moved = SourceMoved::default();
        self.end = End::Open(Some(SettleCheck {
            settled,
            expect,
            moved: moved.clone(),
        }));
        (self, moved)
    }

    /// The next chunk; `Ok(None)` once the sender has finished the body
    /// and its source, where it is checked, settled. Cancel safe: a call
    /// dropped while waiting loses nothing.
    pub async fn next(&mut self) -> Result<Option<Vec<u8>>, BodyError> {
        loop {
            match &mut self.end {
                End::Whole => return Ok(None),
                End::SourceMoved => return Err(BodyError::SourceMoved),
                End::Settling(check) => {
                    let now = (&mut check.settled).await.unwrap_or(OnDisk::Unknown);
                    // Any `Holds` will do: a source's content is
                    // confirmed by the writer, which refuses bytes that do
                    // not hash to the scan's (SPEC §7.2).
                    let held = check.expect.check(now).is_ok();
                    if !held {
                        check.moved.mark();
                    }
                    self.end = if held { End::Whole } else { End::SourceMoved };
                }
                End::Open(_) => {
                    let piece = self.pieces.recv().await;
                    if let Some(bytes) = self.take(piece)? {
                        return Ok(Some(bytes));
                    }
                }
            }
        }
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
                self.end = match std::mem::replace(&mut self.end, End::Whole) {
                    End::Open(Some(check)) => End::Settling(check),
                    _ => End::Whole,
                };
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

#[cfg(test)]
mod tests {
    use super::*;

    const SCANNED: Precondition = Precondition::File {
        size: 5,
        mtime_us: 7,
    };

    /// A whole body of five bytes whose source settled as `now`, read to
    /// its end.
    async fn read_settled_as(now: OnDisk) -> (Vec<Result<Option<Vec<u8>>, String>>, bool) {
        let (settle, settled) = oneshot::channel();
        let (mut body, moved) = Body::from_bytes(b"hello".to_vec()).settling(settled, SCANNED);
        let _ = settle.send(now);
        let mut seen = Vec::new();
        for _ in 0..3 {
            seen.push(body.next().await.map_err(|error| error.to_string()));
        }
        (seen, moved.happened())
    }

    #[tokio::test]
    async fn a_source_that_settled_as_scanned_ends_the_body_whole() {
        let (seen, moved) = read_settled_as(OnDisk::File {
            size: 5,
            mtime_us: 7,
        })
        .await;

        assert_eq!(seen, [Ok(Some(b"hello".to_vec())), Ok(None), Ok(None)]);
        assert!(!moved);
    }

    #[tokio::test]
    async fn a_source_that_moved_fails_the_body_in_place_of_its_end_and_says_so() {
        let (seen, moved) = read_settled_as(OnDisk::File {
            size: 5,
            mtime_us: 8,
        })
        .await;

        let refused = Err(BodyError::SourceMoved.to_string());
        assert_eq!(
            seen,
            [Ok(Some(b"hello".to_vec())), refused.clone(), refused]
        );
        assert!(moved);
    }

    #[tokio::test]
    async fn a_body_cancelled_while_its_source_settles_still_checks_it() {
        let (settle, settled) = oneshot::channel();
        let (mut body, moved) = Body::from_bytes(Vec::new()).settling(settled, SCANNED);

        let waiting = tokio::time::timeout(std::time::Duration::from_millis(10), body.next());
        assert!(waiting.await.is_err(), "the end waits on the source");
        let _ = settle.send(OnDisk::Absent);

        assert!(matches!(body.next().await, Err(BodyError::SourceMoved)));
        assert!(moved.happened());
    }
}
