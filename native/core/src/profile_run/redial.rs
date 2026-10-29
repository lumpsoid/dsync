//! When a `peer://` entry is dialled again (SPEC §11.3): which failures
//! of an attempt may pass on their own, and the budget the re-dials of one
//! drop share. Pure: plain values in, a verdict out.

use std::fmt;
use std::sync::Arc;
use std::time::{Duration, Instant};

use dsync_domain::{Side, Tuning};

use crate::connector::{ConnectError, ConnectFailure};
use crate::run::RunError;

/// What ended an attempt of an entry that is dialled again: its run's
/// failure (a dropped link, or a lock its dropped session still held), or
/// the re-dial's own connect.
#[derive(Clone, Debug)]
pub enum ReconnectCause {
    Run(RunError),
    Connect(Arc<ConnectError>),
}

impl ReconnectCause {
    /// The side the failure is on.
    pub fn side(&self) -> Option<Side> {
        match self {
            ReconnectCause::Run(error) => error.side(),
            ReconnectCause::Connect(error) => Some(error.side),
        }
    }
}

impl fmt::Display for ReconnectCause {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            ReconnectCause::Run(error) => error.fmt(f),
            ReconnectCause::Connect(error) => error.fmt(f),
        }
    }
}

/// Which attempt of an entry failed.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub(crate) enum Attempt {
    /// The entry's first connect and run.
    First,
    /// A connect and run after a drop.
    Redial,
}

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub(crate) enum Verdict {
    /// Dial again, budget allowing.
    Retry,
    /// The entry ends with this failure.
    Final,
}

/// Whether `attempt`, failed with `cause`, is dialled again; `peers` are
/// the entry's `peer://` sides. A run's link drop to a peer always is. A
/// re-dial's connect that found nothing answering, or a link that dropped
/// again, is; so is a lock held on a peer during a re-dial - the dropped
/// session's own, until the far side lets it go. Anything else says the
/// same on the next try, and a first attempt's connect or held lock is the
/// entry's failure as it always was.
pub(crate) fn verdict(attempt: Attempt, cause: &ReconnectCause, peers: &[Side]) -> Verdict {
    let retry = match cause {
        ReconnectCause::Run(error) => {
            error.is_link_drop(peers) || (attempt == Attempt::Redial && error.is_held_on(peers))
        }
        ReconnectCause::Connect(error) => {
            attempt == Attempt::Redial
                && peers.contains(&error.side)
                && matches!(&error.failure, ConnectFailure::Peer(dial) if dial.is_transient())
        }
    };
    if retry {
        Verdict::Retry
    } else {
        Verdict::Final
    }
}

/// The re-dials one drop may still make: a window from the drop, and a
/// backoff that doubles up to its cap. A re-run that gets past its locks
/// opens a fresh one for its own drop.
#[derive(Debug)]
pub(crate) struct Window {
    opened: Instant,
    backoff: Duration,
    tuning: Tuning,
}

impl Window {
    /// A window opened by a drop at `now`.
    pub(crate) fn open(now: Instant, tuning: Tuning) -> Window {
        Window {
            opened: now,
            backoff: tuning.reconnect_backoff,
            tuning,
        }
    }

    /// The wait before the next re-dial, the entry having made `made` in
    /// all, at `now`; `None` when the cap is reached or the wait would end
    /// past the window.
    pub(crate) fn next(&mut self, made: u32, now: Instant) -> Option<Duration> {
        if made >= self.tuning.reconnects_per_entry {
            return None;
        }
        let closes = self.opened + self.tuning.reconnect_window;
        if now + self.backoff > closes {
            return None;
        }
        let wait = self.backoff;
        self.backoff = (self.backoff * 2).min(self.tuning.reconnect_backoff_max);
        Some(wait)
    }
}

#[cfg(test)]
mod tests;
