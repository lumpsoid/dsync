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
}

/// One served session's place in the registry. Dropped once the session
/// has ended and let go of its replica, which is what a reclaim waits for.
pub(crate) struct LiveSession {
    id: u64,
    token: SessionToken,
    end: CancellationToken,
    sessions: Arc<LiveSessions>,
    _gone: watch::Sender<()>,
}

impl LiveSessions {
    /// Issues a token for a new session serving `device`.
    pub(crate) fn register(self: &Arc<Self>, device: DeviceId) -> LiveSession {
        let token = SessionToken::generate();
        let end = CancellationToken::new();
        let (gone_sender, gone) = watch::channel(());
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
            },
        );
        LiveSession {
            id,
            token,
            end,
            sessions: self.clone(),
            _gone: gone_sender,
        }
    }

    /// Ends the live session `claim` names if it serves `device`, and
    /// waits up to `wait` for it to be gone. Whether one was ended.
    pub(crate) async fn reclaim(
        &self,
        claim: &SessionToken,
        device: DeviceId,
        wait: Duration,
    ) -> bool {
        let named = self
            .sessions()
            .live
            .values()
            .find(|live| live.token.is(claim) && live.device == device)
            .map(|live| (live.end.clone(), live.gone.clone()));
        let Some((end, mut gone)) = named else {
            return false;
        };
        end.cancel();
        let _ = tokio::time::timeout(wait, async { while gone.changed().await.is_ok() {} }).await;
        true
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
}

impl Drop for LiveSession {
    fn drop(&mut self) {
        self.sessions.sessions().live.remove(&self.id);
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
        assert!(sessions.reclaim(&token, device(1), WAIT).await);
        assert_eq!(started.elapsed(), Duration::from_secs(1));
        serving.await.unwrap();
        // The token went with its session: claiming it again ends nothing.
        assert!(!sessions.reclaim(&token, device(1), WAIT).await);
    }

    #[tokio::test(start_paused = true)]
    async fn another_device_or_another_token_ends_nothing() {
        let sessions = Arc::new(LiveSessions::default());
        let session = sessions.register(device(1));
        let token = session.token().clone();
        assert!(!sessions.reclaim(&token, device(2), WAIT).await);
        assert!(
            !sessions
                .reclaim(&SessionToken::generate(), device(1), WAIT)
                .await
        );
        assert!(!session.end.is_cancelled());
        // Positive control: the right device with the right token.
        drop(tokio::spawn(async move {
            session.ended().await;
            drop(session);
        }));
        assert!(sessions.reclaim(&token, device(1), WAIT).await);
    }

    #[tokio::test(start_paused = true)]
    async fn a_session_that_will_not_go_is_waited_on_only_so_long() {
        let sessions = Arc::new(LiveSessions::default());
        let session = sessions.register(device(1));
        let started = tokio::time::Instant::now();
        assert!(
            sessions
                .reclaim(&session.token().clone(), device(1), WAIT)
                .await
        );
        assert_eq!(started.elapsed(), WAIT);
        assert!(session.end.is_cancelled());
    }
}
