//! The dialer's memory of the sessions it holds (SPEC §4.2): the token
//! each peer:// connection was issued, by the device, entry and side it
//! serves, so the next dial for the same replica can claim the session a
//! dropped link left behind on the far side.
//!
//! It outlives one attempt on purpose: the CLI makes one per process and
//! the hub one per run session, so a re-dial - or the attempt after the
//! app comes back to the foreground - finds the token the last one was
//! issued. Nothing survives a restart, and nothing needs to: the far side
//! forgets a token with its session.

use std::collections::HashMap;
use std::sync::{Mutex, MutexGuard, PoisonError};

use dsync_domain::{DeviceId, EntryId, Side};

use crate::session_token::SessionToken;

type Replica = (DeviceId, EntryId, Side);

#[derive(Default)]
pub struct PeerSessions {
    tokens: Mutex<HashMap<Replica, SessionToken>>,
}

impl PeerSessions {
    pub fn new() -> PeerSessions {
        PeerSessions::default()
    }

    /// The token the last connection to `device` for `entry`'s `side`
    /// was issued, if one was.
    pub(crate) fn claim(
        &self,
        device: DeviceId,
        entry: &EntryId,
        side: Side,
    ) -> Option<SessionToken> {
        self.tokens().get(&(device, entry.clone(), side)).cloned()
    }

    /// Remembers `token`, issued to the connection that now serves
    /// `entry`'s `side` on `device`, in place of the one before.
    pub(crate) fn hold(&self, device: DeviceId, entry: EntryId, side: Side, token: SessionToken) {
        self.tokens().insert((device, entry, side), token);
    }

    fn tokens(&self) -> MutexGuard<'_, HashMap<Replica, SessionToken>> {
        self.tokens.lock().unwrap_or_else(PoisonError::into_inner)
    }
}
