//! A decider's read of both replicas' current files while the plan is under
//! review (the diff page of a review row).

use dsync_domain::{Comparison, FileText, Offer, PeekLimits, RelPath, Side, Sided};

use crate::replica::{Reading, Replica};
use crate::run::compared::Compared;

/// The run's two replicas, readable while the plan is under review and only
/// then: it borrows the pair [`crate::Run`] holds while it asks the decider,
/// so no read can outlive the review or the run's locks.
///
/// Its reads are not the apply's: they bypass the run's clock, so they do
/// not count in the run's `Read` metrics.
pub struct Peek<'r, A, B> {
    a: &'r A,
    b: &'r B,
    limits: PeekLimits,
}

impl<A, B> Clone for Peek<'_, A, B> {
    fn clone(&self) -> Self {
        *self
    }
}

impl<A, B> Copy for Peek<'_, A, B> {}

/// One side's read, before it is decoded.
enum Fetched {
    Absent,
    Bytes(Vec<u8>),
    TooLarge(u64),
    Unreadable(String),
}

impl<'r, A: Replica, B: Replica> Peek<'r, A, B> {
    pub(crate) fn new(a: &'r A, b: &'r B, limits: PeekLimits) -> Self {
        Peek { a, b, limits }
    }

    /// Both sides' current text for `comparison`; refused unread when its
    /// offer is not [`Offer::Readable`]. A side with no file in the
    /// comparison is not read and is `None`. Both sides are read at once;
    /// when both fail, `old`'s failure is reported. Dropping the future
    /// drops the reads.
    pub async fn compare(&self, comparison: &Comparison) -> Compared {
        match comparison.offer(&self.limits) {
            Offer::Media => return Compared::Media,
            Offer::TooLarge { side, size } => return Compared::TooLarge { side, size },
            Offer::Readable => {}
        }
        let path = &comparison.path;
        let (old, new) = tokio::join!(
            self.fetch(path, comparison.old),
            self.fetch(path, comparison.new)
        );
        let old = match text(comparison.old.side, old) {
            Ok(old) => old,
            Err(refused) => return refused,
        };
        match text(comparison.new.side, new) {
            Ok(new) => Compared::Texts { old, new },
            Err(refused) => refused,
        }
    }

    async fn fetch(&self, path: &RelPath, sided: Sided) -> Fetched {
        if sided.size.is_none() {
            return Fetched::Absent;
        }
        match sided.side {
            Side::A => capped(self.a, path, self.limits.max_bytes).await,
            Side::B => capped(self.b, path, self.limits.max_bytes).await,
        }
    }
}

/// `path`'s bytes on `replica`, at most `max_bytes` of them: one byte more
/// and the body is dropped, which ends the read. What the file settled to
/// is not asked: a peek checks nothing.
async fn capped<R: Replica>(replica: &R, path: &RelPath, max_bytes: u64) -> Fetched {
    let Reading { mut body, .. } = match replica.read(path).await {
        Ok(reading) => reading,
        Err(error) => return Fetched::Unreadable(error.to_string()),
    };
    let mut bytes = Vec::new();
    loop {
        match body.next().await {
            Ok(Some(chunk)) => {
                bytes.extend_from_slice(&chunk);
                let seen = bytes.len() as u64;
                if seen > max_bytes {
                    return Fetched::TooLarge(seen);
                }
            }
            Ok(None) => return Fetched::Bytes(bytes),
            Err(error) => return Fetched::Unreadable(error.to_string()),
        }
    }
}

/// `side`'s text, or the [`Compared`] that refuses the comparison.
fn text(side: Side, fetched: Fetched) -> Result<Option<FileText>, Compared> {
    match fetched {
        Fetched::Absent => Ok(None),
        Fetched::Bytes(bytes) => FileText::decode(bytes)
            .map(Some)
            .map_err(|_| Compared::Binary { side }),
        Fetched::TooLarge(size) => Err(Compared::TooLarge { side, size }),
        Fetched::Unreadable(message) => Err(Compared::Unreadable { side, message }),
    }
}
