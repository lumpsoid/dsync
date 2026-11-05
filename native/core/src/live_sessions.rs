//! A peer listener's registry of the sessions it is serving (SPEC §4.2),
//! by the token each was issued, so a dialer whose link dropped can end
//! the session it left behind - and free that session's locks - when it
//! dials again, instead of waiting out the far side's silence limit.
//!
//! The gate is identity: the claim must name a live session and come from
//! the device that session serves. Anything else - an unknown token, one
//! whose session has ended, another device's - is ignored, with no reply
//! that tells them apart. A token lives exactly as long as its session:
//! the entry goes when the session's [`LiveSession`] does.

use std::collections::HashMap;
use std::sync::{Arc, Mutex, MutexGuard, PoisonError};
use std::time::Duration;

use dsync_domain::DeviceId;
use tokio::sync::watch;
use tokio_util::sync::{CancellationToken, WaitForCancellationFutureOwned};

use crate::session_token::SessionToken;
use crate::spool_drain::{DrainProbe, SpoolDrain};

#[derive(Default)]
pub(crate) struct LiveSessions {
    sessions: Mutex<Sessions>,
}

#[derive(Default)]
struct Sessions {
    next: u64,
    live: HashMap<u64, Live>,
}

struct Live {
    token: SessionToken,
    device: DeviceId,
    end: CancellationToken,
    /// Closes when the session's [`LiveSession`] drops.
    gone: watch::Receiver<()>,
    /// How to sample the session's spool drain, once it has opened its
    /// replica.
    drain: watch::Receiver<Option<DrainProbe>>,
}

/// One served session's place in the registry. Dropped once the session
/// has ended and let go of its replica, which is what a reclaim waits for.
pub(crate) struct LiveSession {
    id: u64,
    token: SessionToken,
    end: CancellationToken,
    sessions: Arc<LiveSessions>,
    drain: watch::Sender<Option<DrainProbe>>,
    _gone: watch::Sender<()>,
}

/// A live session a claim has ended, as the listener waits for it to go.
pub(crate) struct Ending {
    gone: watch::Receiver<()>,
    drain: watch::Receiver<Option<DrainProbe>>,
}

impl LiveSessions {
    /// Issues a token for a new session serving `device`.
    pub(crate) fn register(self: &Arc<Self>, device: DeviceId) -> LiveSession {
        let token = SessionToken::generate();
        let end = CancellationToken::new();
        let (gone_sender, gone) = watch::channel(());
        let (drain_sender, drain) = watch::channel(None);
        let mut sessions = self.sessions();
        let id = sessions.next;
        sessions.next += 1;
        sessions.live.insert(
            id,
            Live {
                token: token.clone(),
                device,
                end: end.clone(),
                gone,
                drain,
            },
        );
        LiveSession {
            id,
            token,
            end,
            sessions: self.clone(),
            drain: drain_sender,
            _gone: gone_sender,
        }
    }

    /// Ends the live session `claim` names if it serves `device`: how to
    /// wait for it to go. `None` when the claim names no such session.
    pub(crate) fn end(&self, claim: &SessionToken, device: DeviceId) -> Option<Ending> {
        let sessions = self.sessions();
        let live = sessions
            .live
            .values()
            .find(|live| live.token.is(claim) && live.device == device)?;
        live.end.cancel();
        Some(Ending {
            gone: live.gone.clone(),
            drain: live.drain.clone(),
        })
    }

    fn sessions(&self) -> MutexGuard<'_, Sessions> {
        self.sessions.lock().unwrap_or_else(PoisonError::into_inner)
    }
}

impl LiveSession {
    pub(crate) fn token(&self) -> &SessionToken {
        &self.token
    }

    /// Fires when a reclaim ends this session.
    pub(crate) fn ended(&self) -> WaitForCancellationFutureOwned {
        self.end.clone().cancelled_owned()
    }

    /// Where this session publishes how to sample its spool drain, for a
    /// reclaim waiting on it.
    pub(crate) fn drain_publisher(&self) -> watch::Sender<Option<DrainProbe>> {
        self.drain.clone()
    }
}

impl Drop for LiveSession {
    fn drop(&mut self) {
        self.sessions.sessions().live.remove(&self.id);
    }
}

impl Ending {
    /// Waits up to `wait` for the session to be gone; whether it is.
    pub(crate) async fn gone_within(&mut self, wait: Duration) -> bool {
        let gone = async { while self.gone.changed().await.is_ok() {} };
        tokio::time::timeout(wait, gone).await.is_ok()
    }

    /// The session's spool drain now: nothing queued and not busy while
    /// it has no replica open, no spool, or has let its replica go.
    pub(crate) fn drain(&self) -> SpoolDrain {
        // Cloned out: the probe runs with no lock of the watch held.
        let probe = self.drain.borrow().clone();
        probe.and_then(|probe| probe()).unwrap_or_default()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const WAIT: Duration = Duration::from_secs(5);

    fn device(byte: u8) -> DeviceId {
        DeviceId::from_spki_der(&[byte])
    }

    #[tokio::test(start_paused = true)]
    async fn the_same_device_ends_its_session_and_waits_for_it_to_go() {
        let sessions = Arc::new(LiveSessions::default());
        let session = sessions.register(device(1));
        let token = session.token().clone();
        let ended = session.ended();
        let serving = tokio::spawn(async move {
            ended.await;
            tokio::time::sleep(Duration::from_secs(1)).await;
            drop(session);
        });
        let started = tokio::time::Instant::now();
        let mut ending = sessions.end(&token, device(1)).unwrap();
        assert!(ending.gone_within(WAIT).await);
        assert_eq!(started.elapsed(), Duration::from_secs(1));
        serving.await.unwrap();
        // The token went with its session: claiming it again ends nothing.
        assert!(sessions.end(&token, device(1)).is_none());
    }

    #[tokio::test(start_paused = true)]
    async fn another_device_or_another_token_ends_nothing() {
        let sessions = Arc::new(LiveSessions::default());
        let session = sessions.register(device(1));
        let token = session.token().clone();
        assert!(sessions.end(&token, device(2)).is_none());
        assert!(sessions.end(&SessionToken::generate(), device(1)).is_none());
        assert!(!session.end.is_cancelled());
        // Positive control: the right device with the right token.
        assert!(sessions.end(&token, device(1)).is_some());
        assert!(session.end.is_cancelled());
    }

    #[tokio::test(start_paused = true)]
    async fn a_session_that_will_not_go_is_waited_on_only_so_long() {
        let sessions = Arc::new(LiveSessions::default());
        let session = sessions.register(device(1));
        let started = tokio::time::Instant::now();
        let mut ending = sessions.end(&session.token().clone(), device(1)).unwrap();
        assert!(!ending.gone_within(WAIT).await);
        assert_eq!(started.elapsed(), WAIT);
        assert!(session.end.is_cancelled());
    }

    /// What the session's probe samples is what its reclaim reads, each
    /// time it asks; nothing until the session publishes one.
    #[tokio::test(start_paused = true)]
    async fn an_ending_samples_the_drain_its_session_publishes() {
        let sessions = Arc::new(LiveSessions::default());
        let session = sessions.register(device(1));
        let ending = sessions.end(&session.token().clone(), device(1)).unwrap();
        assert_eq!(ending.drain(), SpoolDrain::default());
        let (set, now) = watch::channel(SpoolDrain {
            queued_bytes: 4096,
            busy: true,
        });
        let probe: DrainProbe = Arc::new(move || Some(*now.borrow()));
        session.drain_publisher().send_replace(Some(probe));
        assert_eq!(ending.drain().queued_bytes, 4096);
        set.send_replace(SpoolDrain {
            queued_bytes: 0,
            busy: true,
        });
        assert_eq!(
            ending.drain(),
            SpoolDrain {
                queued_bytes: 0,
                busy: true
            }
        );
    }
}
