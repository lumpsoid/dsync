//! Snapshots leave a session one at a time and in the order they were
//! taken, though each is built and sent away from the session's lock. One
//! taken while another is on its way waits, and a later one replaces it.
//! The replaced one is never sent, and the next is diffed against what
//! was (`rows.rs`'s `Delivered`), so nothing it changed is lost: the head
//! misses only a state it would have drawn over at once.

/// Whether a snapshot is on its way, and the one waiting behind it.
pub(super) enum Sending<T> {
    Idle,
    Busy { waiting: Option<T> },
}

impl<T> Sending<T> {
    /// `snapshot` was taken: `Some` to send it now (the caller now sends),
    /// `None` when it waits behind the one on its way.
    pub(super) fn offer(&mut self, snapshot: T) -> Option<T> {
        match self {
            Sending::Idle => {
                *self = Sending::Busy { waiting: None };
                Some(snapshot)
            }
            Sending::Busy { waiting } => {
                *waiting = Some(snapshot);
                None
            }
        }
    }

    /// The one on its way was sent: the next to send, if one waits.
    pub(super) fn sent(&mut self) -> Option<T> {
        match self {
            Sending::Idle => None,
            Sending::Busy { waiting } => {
                let next = waiting.take();
                if next.is_none() {
                    *self = Sending::Idle;
                }
                next
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::Sending;

    #[test]
    fn a_snapshot_goes_at_once_when_nothing_is_on_its_way() {
        let mut sending = Sending::Idle;
        assert_eq!(sending.offer(1), Some(1));
        assert_eq!(sending.sent(), None);
        assert_eq!(sending.offer(2), Some(2), "idle again");
    }

    #[test]
    fn snapshots_taken_meanwhile_wait_and_only_the_latest_goes() {
        let mut sending = Sending::Idle;
        assert_eq!(sending.offer(1), Some(1));
        assert_eq!(sending.offer(2), None);
        assert_eq!(sending.offer(3), None);
        assert_eq!(sending.sent(), Some(3));
        assert_eq!(sending.offer(4), None, "3 is still on its way");
        assert_eq!(sending.sent(), Some(4));
        assert_eq!(sending.sent(), None);
        assert_eq!(sending.offer(5), Some(5));
    }
}
