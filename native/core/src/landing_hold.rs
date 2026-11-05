//! Test support only, behind the `test-support` feature: holds the
//! landings of every replica writing under one root at its writers, each
//! as a writer takes it and before it touches anything, so a test can
//! keep writers busy without timing. A landing inside a spool's Lander or
//! a far replica server is reached the same way as a plain write's, since
//! the hold is found by the root, not by the replica.

use std::path::{Path, PathBuf};
use std::sync::{Arc, Condvar, Mutex, MutexGuard, PoisonError};

use tokio::sync::watch;

/// Every hold in force, by the root it holds.
static HOLDS: Mutex<Vec<(PathBuf, Arc<Gate>)>> = Mutex::new(Vec::new());

/// Holds the landings onto a root until released; released on drop.
pub struct LandingHold {
    root: PathBuf,
    gate: Arc<Gate>,
}

struct Gate {
    passes: Mutex<Passes>,
    opened: Condvar,
    /// Landings that reached the hold, ever.
    arrived: watch::Sender<u64>,
    /// Landings waiting at it now.
    held: watch::Sender<usize>,
}

/// Which landings the hold lets on.
struct Passes {
    open: bool,
    /// Landings let on one at a time, not yet taken.
    one_each: u64,
}

impl LandingHold {
    /// Holds every landing onto `root`, as its replica names it, from now.
    pub fn at(root: &Path) -> LandingHold {
        let gate = Arc::new(Gate {
            passes: Mutex::new(Passes {
                open: false,
                one_each: 0,
            }),
            opened: Condvar::new(),
            arrived: watch::Sender::new(0),
            held: watch::Sender::new(0),
        });
        holds().push((root.to_path_buf(), gate.clone()));
        LandingHold {
            root: root.to_path_buf(),
            gate,
        }
    }

    /// Lets one held landing, or the next to arrive, on.
    pub fn release_one(&self) {
        self.gate.passes().one_each += 1;
        self.gate.opened.notify_all();
    }

    /// Lets every landing on, held or still to come.
    pub fn release(&self) {
        self.gate.passes().open = true;
        self.gate.opened.notify_all();
    }

    /// Waits until `count` landings wait at the hold at once.
    pub async fn until_held(&self, count: usize) {
        let _ = self
            .gate
            .held
            .subscribe()
            .wait_for(|held| *held >= count)
            .await;
    }

    /// Waits until `count` landings have reached the hold, held or let on.
    pub async fn until_arrived(&self, count: u64) {
        let _ = self
            .gate
            .arrived
            .subscribe()
            .wait_for(|arrived| *arrived >= count)
            .await;
    }

    /// Landings waiting at the hold now.
    pub fn held(&self) -> usize {
        *self.gate.held.borrow()
    }
}

impl Drop for LandingHold {
    fn drop(&mut self) {
        self.release();
        holds().retain(|(root, gate)| !(root == &self.root && Arc::ptr_eq(gate, &self.gate)));
    }
}

impl Gate {
    fn passes(&self) -> MutexGuard<'_, Passes> {
        self.passes.lock().unwrap_or_else(PoisonError::into_inner)
    }
}

fn holds() -> MutexGuard<'static, Vec<(PathBuf, Arc<Gate>)>> {
    HOLDS.lock().unwrap_or_else(PoisonError::into_inner)
}

/// Waits, on a writer thread, while a hold on `root` keeps its landings.
pub(crate) fn pass(root: &Path) {
    let gate = holds()
        .iter()
        .find(|(held, _)| held == root)
        .map(|(_, gate)| gate.clone());
    let Some(gate) = gate else { return };
    gate.arrived.send_modify(|arrived| *arrived += 1);
    gate.held.send_modify(|held| *held += 1);
    let mut passes = gate.passes();
    while !passes.open && passes.one_each == 0 {
        passes = gate
            .opened
            .wait(passes)
            .unwrap_or_else(PoisonError::into_inner);
    }
    if !passes.open {
        passes.one_each -= 1;
    }
    drop(passes);
    gate.held.send_modify(|held| *held -= 1);
}
