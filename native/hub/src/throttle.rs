//! How often a session's snapshots go out: a change the head must see at
//! once goes at once, and routine ones (progress, the scan's facts, a
//! connection's line) at most once per [`REFRESH_INTERVAL`], the latest
//! state each time. Pure: a session asks [`Throttle::on`] and carries out
//! the [`Verdict`]; it owns the timer.

use std::time::Duration;

use tokio::time::Instant;

/// The head redraws progress no more often than this (SPEC §11.4).
pub const REFRESH_INTERVAL: Duration = Duration::from_secs(1);

/// How soon a change has to reach the head.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub(crate) enum Urgency {
    /// Nothing the head shows changed.
    Unseen,
    /// Routine: at most one snapshot per refresh interval.
    Routine,
    /// A phase, a question, or the answer to a tap: at once.
    Now,
}

/// What a session does about a change.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub(crate) enum Verdict {
    /// Send the state as it now stands.
    Send,
    /// Ask again with [`Throttle::due`] at this instant.
    DeferUntil(Instant),
    /// Nothing: unseen, or a send is already due.
    Nothing,
}

/// Whether a routine change waits on the timer.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
enum Flush {
    /// No timer is set.
    Idle,
    /// A timer is set; `dirty`: a change it must send has come since.
    Due { dirty: bool },
}

/// One session's refresh decisions.
#[derive(Debug)]
pub(crate) struct Throttle {
    last_sent: Option<Instant>,
    flush: Flush,
}

impl Throttle {
    /// Nothing sent yet: the first change goes at once.
    pub(crate) fn new() -> Throttle {
        Throttle {
            last_sent: None,
            flush: Flush::Idle,
        }
    }

    /// A change of `urgency` came at `now`. `Send` counts as sent.
    pub(crate) fn on(&mut self, urgency: Urgency, now: Instant) -> Verdict {
        match urgency {
            Urgency::Unseen => Verdict::Nothing,
            Urgency::Now => self.sent(now),
            Urgency::Routine => match self.last_sent {
                Some(last) if now < last + REFRESH_INTERVAL => match self.flush {
                    Flush::Idle => {
                        self.flush = Flush::Due { dirty: true };
                        Verdict::DeferUntil(last + REFRESH_INTERVAL)
                    }
                    Flush::Due { .. } => {
                        self.flush = Flush::Due { dirty: true };
                        Verdict::Nothing
                    }
                },
                _ => self.sent(now),
            },
        }
    }

    /// The timer a `DeferUntil` asked for fired at `now`: `Send` when a
    /// routine change has not gone out since.
    pub(crate) fn due(&mut self, now: Instant) -> Verdict {
        let dirty = matches!(self.flush, Flush::Due { dirty: true });
        self.flush = Flush::Idle;
        if dirty {
            self.sent(now)
        } else {
            Verdict::Nothing
        }
    }

    fn sent(&mut self, now: Instant) -> Verdict {
        self.last_sent = Some(now);
        if let Flush::Due { .. } = self.flush {
            // What the timer would have sent goes now.
            self.flush = Flush::Due { dirty: false };
        }
        Verdict::Send
    }
}

#[cfg(test)]
mod tests {
    use std::time::Duration;

    use tokio::time::Instant;

    use super::{REFRESH_INTERVAL, Throttle, Urgency, Verdict};

    const TICK: Duration = Duration::from_millis(10);

    #[test]
    fn the_first_change_and_every_urgent_one_go_at_once() {
        let start = Instant::now();
        let mut throttle = Throttle::new();
        assert_eq!(throttle.on(Urgency::Routine, start), Verdict::Send);
        assert_eq!(throttle.on(Urgency::Now, start + TICK), Verdict::Send);
        assert_eq!(throttle.on(Urgency::Now, start + TICK * 2), Verdict::Send);
    }

    #[test]
    fn an_unseen_change_sends_nothing() {
        let mut throttle = Throttle::new();
        assert_eq!(
            throttle.on(Urgency::Unseen, Instant::now()),
            Verdict::Nothing
        );
    }

    #[test]
    fn a_burst_of_routine_changes_waits_for_one_send_at_the_interval_s_end() {
        let start = Instant::now();
        let mut throttle = Throttle::new();
        throttle.on(Urgency::Now, start);
        assert_eq!(
            throttle.on(Urgency::Routine, start + TICK),
            Verdict::DeferUntil(start + REFRESH_INTERVAL)
        );
        for n in 2..50 {
            assert_eq!(
                throttle.on(Urgency::Routine, start + TICK * n),
                Verdict::Nothing
            );
        }
        let end = start + REFRESH_INTERVAL;
        assert_eq!(throttle.due(end), Verdict::Send);
        // The next routine change waits out a fresh interval.
        assert_eq!(
            throttle.on(Urgency::Routine, end + TICK),
            Verdict::DeferUntil(end + REFRESH_INTERVAL)
        );
    }

    #[test]
    fn an_urgent_send_takes_what_the_timer_would_have_sent() {
        let start = Instant::now();
        let mut throttle = Throttle::new();
        throttle.on(Urgency::Now, start);
        throttle.on(Urgency::Routine, start + TICK);
        assert_eq!(throttle.on(Urgency::Now, start + TICK * 2), Verdict::Send);
        assert_eq!(throttle.due(start + REFRESH_INTERVAL), Verdict::Nothing);
    }

    #[test]
    fn a_routine_change_after_a_quiet_interval_goes_at_once() {
        let start = Instant::now();
        let mut throttle = Throttle::new();
        throttle.on(Urgency::Now, start);
        assert_eq!(
            throttle.on(Urgency::Routine, start + REFRESH_INTERVAL),
            Verdict::Send
        );
    }
}
