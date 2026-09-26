//! The live sessions a command started - runs, serving, pairing windows -
//! by session id, and the handles the commands that steer them need.
//! A session's task removes its own entry when it ends.

use std::collections::HashMap;
use std::future::Future;
use std::sync::{Arc, Mutex, PoisonError};

use tokio::sync::oneshot;
use tokio::task::AbortHandle;

use crate::run::RunControl;
use crate::serve::Serving;

/// How a command reaches a running session.
pub enum Session {
    Run(Arc<RunControl>),
    Serve(Serving),
    Pairing(PairingControl),
}

pub struct PairingControl {
    pub task: AbortHandle,
    /// The operator's answer for the device waiting to be confirmed, while
    /// one is.
    pub pending: Arc<Mutex<Option<oneshot::Sender<bool>>>>,
}

#[derive(Clone, Default)]
pub struct Sessions(Arc<Mutex<HashMap<u64, Session>>>);

impl Sessions {
    fn lock(&self) -> std::sync::MutexGuard<'_, HashMap<u64, Session>> {
        self.0.lock().unwrap_or_else(PoisonError::into_inner)
    }

    /// Runs `work` as session `id`, registered under the handle `control`
    /// builds from the task's abort handle. Registered before the task can
    /// end, so its own removal always finds it.
    pub fn spawn(
        &self,
        id: u64,
        control: impl FnOnce(AbortHandle) -> Session,
        work: impl Future<Output = ()> + Send + 'static,
    ) {
        let sessions = self.clone();
        let mut live = self.lock();
        let task = tokio::spawn(async move {
            work.await;
            sessions.lock().remove(&id);
        });
        live.insert(id, control(task.abort_handle()));
    }

    /// Takes session `id` out when it is the kind `wanted` accepts: the
    /// caller is ending it.
    pub fn take_if(&self, id: u64, wanted: impl FnOnce(&Session) -> bool) -> Option<Session> {
        let mut live = self.lock();
        if live.get(&id).is_some_and(wanted) {
            live.remove(&id)
        } else {
            None
        }
    }

    /// `act` on session `id`, if it is live.
    pub fn with<T>(&self, id: u64, act: impl FnOnce(&Session) -> T) -> Option<T> {
        self.lock().get(&id).map(act)
    }
}
