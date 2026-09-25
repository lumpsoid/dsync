//! Per-stream credit (SPEC §4.2): how much of a body its sender may put on
//! the wire before the receiver has made room for it.
//!
//! **Each body is bounded on its own, by its sender.** A body starts with
//! [`STREAM_CREDIT_BYTES`] it may send without asking; past that its sender
//! waits for `Credit` frames, which the receiver sends as its consumer
//! takes the bytes ([`crate::inbound`]). So a body nobody is taking - a
//! read admitted ahead of a worker slot, a write queued for a writer -
//! holds at most its credit at the receiver, and the reader never has to
//! stop reading on its account: the frames of every other exchange keep
//! arriving past it.
//!
//! This is the sending half: the credit of every body this end is sending,
//! by exchange id, topped up as grants arrive.

use std::collections::HashMap;
use std::sync::{Arc, Mutex, MutexGuard, PoisonError};

use tokio::sync::Notify;

use crate::frame::{Frame, Kind};
use crate::link_error::LinkError;

/// What a body may send before its first grant, and the most its receiver
/// holds of it untaken: 4 chunks, so a sender that is granted as the
/// receiver takes never waits on a link under ~50 MiB/s per stream at a
/// 5 ms round trip.
pub(crate) const STREAM_CREDIT_BYTES: usize = 256 * 1024;

/// Bytes a receiver lets its consumer take before it grants them back, in
/// one frame: half the credit, so a body that fits in it - most files -
/// never costs a `Credit` frame.
pub(crate) const GRANT_BYTES: usize = STREAM_CREDIT_BYTES / 2;

/// The frame granting `bytes` more to the body of exchange `id`.
pub(crate) fn grant_frame(id: u32, bytes: usize) -> Frame {
    let bytes = u32::try_from(bytes).expect("a grant is at most the stream's credit");
    Frame::new(Kind::Credit, id, bytes.to_be_bytes().to_vec())
}

/// The bytes a `Credit` frame grants.
pub(crate) fn granted(frame: &Frame) -> Result<usize, LinkError> {
    let bytes: [u8; 4] = frame
        .payload
        .as_slice()
        .try_into()
        .map_err(|_| LinkError::Protocol("a credit frame that is not four bytes".into()))?;
    Ok(u32::from_be_bytes(bytes) as usize)
}

/// The credit of every body this end is sending.
pub(crate) struct Credits {
    state: Mutex<State>,
}

struct State {
    open: HashMap<u32, Arc<Stream>>,
    /// The connection is over: every credit open or opened later is too.
    closed: bool,
}

struct Stream {
    left: Mutex<Left>,
    granted: Notify,
}

struct Left {
    bytes: usize,
    closed: bool,
}

impl Credits {
    pub fn new() -> Arc<Credits> {
        Arc::new(Credits {
            state: Mutex::new(State {
                open: HashMap::new(),
                closed: false,
            }),
        })
    }

    fn state(&self) -> MutexGuard<'_, State> {
        self.state.lock().unwrap_or_else(PoisonError::into_inner)
    }

    /// The credit of the body about to be sent under exchange `id`,
    /// opened before anything can grant it more.
    pub fn open(self: &Arc<Self>, id: u32) -> Credit {
        let mut state = self.state();
        let stream = Arc::new(Stream {
            left: Mutex::new(Left {
                bytes: STREAM_CREDIT_BYTES,
                closed: state.closed,
            }),
            granted: Notify::new(),
        });
        state.open.insert(id, stream.clone());
        Credit {
            id,
            stream,
            credits: self.clone(),
        }
    }

    /// Adds `bytes` to exchange `id`'s credit. A grant for a body no
    /// longer being sent - ended, or its sender gone - is dropped.
    pub fn grant(&self, id: u32, bytes: usize) {
        if let Some(stream) = self.state().open.get(&id) {
            let mut left = stream.left();
            left.bytes = left.bytes.saturating_add(bytes);
            stream.granted.notify_one();
        }
    }

    /// Ends every credit: the connection is over, and a sender waiting
    /// for a grant stops waiting.
    pub fn close(&self) {
        let mut state = self.state();
        state.closed = true;
        for stream in state.open.values() {
            stream.left().closed = true;
            stream.granted.notify_one();
        }
    }
}

impl Stream {
    fn left(&self) -> MutexGuard<'_, Left> {
        self.left.lock().unwrap_or_else(PoisonError::into_inner)
    }
}

/// One body's credit, held by its sender; its grants stop being taken
/// once it is dropped.
pub(crate) struct Credit {
    id: u32,
    stream: Arc<Stream>,
    credits: Arc<Credits>,
}

impl Credit {
    /// Takes up to `most` bytes of credit, waiting while there is none;
    /// `None` once the connection is over.
    pub async fn take(&self, most: usize) -> Option<usize> {
        loop {
            {
                let mut left = self.stream.left();
                if left.closed {
                    return None;
                }
                if left.bytes > 0 {
                    let taken = most.min(left.bytes);
                    left.bytes -= taken;
                    return Some(taken);
                }
            }
            self.stream.granted.notified().await;
        }
    }
}

impl Drop for Credit {
    fn drop(&mut self) {
        self.credits.state().open.remove(&self.id);
    }
}

#[cfg(test)]
mod tests {
    use std::time::Duration;

    use super::*;

    const DEADLINE: Duration = Duration::from_secs(5);

    async fn waits(credit: &Credit) -> bool {
        tokio::time::timeout(Duration::from_millis(50), credit.take(1))
            .await
            .is_err()
    }

    #[tokio::test]
    async fn a_body_sends_its_opening_credit_then_waits_for_a_grant() {
        let credits = Credits::new();
        let credit = credits.open(1);
        assert_eq!(credit.take(usize::MAX).await, Some(STREAM_CREDIT_BYTES));
        assert!(waits(&credit).await);

        credits.grant(1, 10);
        assert_eq!(credit.take(4).await, Some(4));
        assert_eq!(credit.take(100).await, Some(6));
    }

    #[tokio::test]
    async fn a_grant_wakes_a_sender_already_waiting() {
        let credits = Credits::new();
        let credit = credits.open(1);
        credit.take(STREAM_CREDIT_BYTES).await;
        let (taken, ()) = tokio::time::timeout(DEADLINE, async {
            tokio::join!(credit.take(64), async {
                tokio::task::yield_now().await;
                credits.grant(1, 64);
            })
        })
        .await
        .unwrap();
        assert_eq!(taken, Some(64));
    }

    #[tokio::test]
    async fn grants_go_to_their_own_body_and_one_for_a_body_gone_is_dropped() {
        let credits = Credits::new();
        let (one, two) = (credits.open(1), credits.open(2));
        one.take(STREAM_CREDIT_BYTES).await;
        two.take(STREAM_CREDIT_BYTES).await;
        drop(two);

        credits.grant(2, 64);
        assert!(waits(&one).await);
        credits.grant(1, 64);
        assert_eq!(one.take(usize::MAX).await, Some(64));
        assert!(credits.state().open.keys().eq([&1]));
    }

    #[tokio::test]
    async fn closing_ends_every_credit_open_and_opened_later() {
        let credits = Credits::new();
        let open = credits.open(1);
        open.take(STREAM_CREDIT_BYTES).await;
        credits.close();
        assert_eq!(
            tokio::time::timeout(DEADLINE, open.take(1)).await.unwrap(),
            None
        );
        assert_eq!(credits.open(2).take(1).await, None);
    }

    #[test]
    fn a_grant_travels_as_four_big_endian_bytes() {
        let frame = grant_frame(7, 0x0102_0304);
        assert_eq!((frame.kind, frame.id), (Kind::Credit, 7));
        assert_eq!(frame.payload, [1, 2, 3, 4]);
        assert_eq!(granted(&frame).unwrap(), 0x0102_0304);
        assert!(granted(&Frame::new(Kind::Credit, 7, vec![1, 2])).is_err());
    }
}
