//! How many of a connection's operations may be outstanding at once, and
//! which may overlap at all (SPEC §4.2's window).
//!
//! **Why a window.** Every remote operation costs a round trip, so a
//! connection's throughput is the window divided by the round-trip time;
//! with several operations outstanding there is traffic both ways and no
//! idle gap for a phone's radio to doze in. The bound exists so a peer is
//! not flooded, not to meter the work.
//!
//! **The rules:** at most `size` operations run at once, admitted in the
//! order they asked (fair: a barrier behind a steady stream of windowed
//! operations is not starved). Operations on one path run one at a time,
//! in the order they were issued - a write then the commit carrying its
//! path is the order the archive rule rests on (SPEC §7.3) - while
//! operations on different paths overlap freely. A barrier waits for every
//! operation issued before it, runs alone, and holds everything issued
//! after it until it finishes.
//!
//! Pure scheduling: no I/O, testable with plain futures. Every hold is a
//! [`Slot`] guard, so an operation that fails, panics or is cancelled
//! gives its place back.

use std::collections::{BTreeSet, HashMap};
use std::sync::{Arc, Mutex, PoisonError};

use dsync_domain::RelPath;
use tokio::sync::{OwnedSemaphorePermit, Semaphore, watch};

pub(crate) struct RequestWindow {
    slots: Arc<Semaphore>,
    size: u32,
    issued: Arc<Mutex<Issued>>,
}

/// What every new operation must wait for. Each receiver stands for one
/// operation and reports only that it is over (its sender dropped), never
/// how it ended.
#[derive(Default)]
struct Issued {
    /// The most recent operation issued on each path, however far it has
    /// got; one entry per path in flight.
    paths: HashMap<RelPath, watch::Receiver<()>>,
    /// The most recent barrier, until it finishes.
    barrier: Option<watch::Receiver<()>>,
}

/// A place in the window. Dropping it lets the next operation in.
#[must_use]
pub(crate) struct Slot {
    // Declared first, so it is given back before the operation is marked
    // over, as the window's order has it.
    _permit: OwnedSemaphorePermit,
    _chain: Chain,
}

/// An operation's place in [`Issued`].
struct Chain {
    issued: Arc<Mutex<Issued>>,
    paths: BTreeSet<RelPath>,
    /// Dropped when the operation is over, which wakes its successors.
    _done: watch::Sender<()>,
    marker: watch::Receiver<()>,
}

impl RequestWindow {
    pub fn new(size: usize) -> RequestWindow {
        let size = u32::try_from(size.max(1)).expect("a request window fits in a u32");
        RequestWindow {
            slots: Arc::new(Semaphore::new(size as usize)),
            size,
            issued: Arc::new(Mutex::new(Issued::default())),
        }
    }

    /// A place for an operation on `paths` (several for a commit batch):
    /// behind the last operation issued on each of them and the last
    /// barrier, then behind the window's bound.
    pub async fn enter(&self, paths: impl IntoIterator<Item = RelPath>) -> Slot {
        let paths: BTreeSet<RelPath> = paths.into_iter().collect();
        let (chain, predecessors) = self.issue(paths, |issued, marker, paths| {
            let mut predecessors: Vec<_> = paths
                .iter()
                .filter_map(|path| issued.paths.insert(path.clone(), marker.clone()))
                .collect();
            predecessors.extend(issued.barrier.clone());
            predecessors
        });
        // Before taking a slot, never while holding one: the predecessors
        // hold theirs (or are about to) and will give them up, so this
        // cannot deadlock.
        for predecessor in predecessors {
            wait_over(predecessor).await;
        }
        let permit = self
            .slots
            .clone()
            .acquire_owned()
            .await
            .expect("the window's semaphore is never closed");
        Slot {
            _permit: permit,
            _chain: chain,
        }
    }

    /// The whole window: every operation issued before this call finishes
    /// first, and nothing issued after starts until the slot is dropped.
    pub async fn barrier(&self) -> Slot {
        let (chain, predecessors) = self.issue(BTreeSet::new(), |issued, marker, _| {
            // Everything issued so far, including an operation still held
            // behind an earlier one on its own path: it has not reached the
            // semaphore yet, so the bound below would not see it.
            let mut predecessors: Vec<_> = issued.paths.values().cloned().collect();
            predecessors.extend(issued.barrier.replace(marker.clone()));
            predecessors
        });
        for predecessor in predecessors {
            wait_over(predecessor).await;
        }
        let permit = self
            .slots
            .clone()
            .acquire_many_owned(self.size)
            .await
            .expect("the window's semaphore is never closed");
        Slot {
            _permit: permit,
            _chain: chain,
        }
    }

    /// Records a new operation under one lock, so two calls chain in call
    /// order rather than in whatever order they are resumed in, and hands
    /// back what it must wait for. The chain exists before any wait, so a
    /// caller cancelled while it waits still marks itself over.
    fn issue(
        &self,
        paths: BTreeSet<RelPath>,
        record: impl FnOnce(
            &mut Issued,
            &watch::Receiver<()>,
            &BTreeSet<RelPath>,
        ) -> Vec<watch::Receiver<()>>,
    ) -> (Chain, Vec<watch::Receiver<()>>) {
        let (done, marker) = watch::channel(());
        let predecessors = record(&mut lock(&self.issued), &marker, &paths);
        let chain = Chain {
            issued: self.issued.clone(),
            paths,
            _done: done,
            marker,
        };
        (chain, predecessors)
    }
}

impl Drop for Chain {
    fn drop(&mut self) {
        let mut issued = lock(&self.issued);
        for path in &self.paths {
            if issued
                .paths
                .get(path)
                .is_some_and(|tail| tail.same_channel(&self.marker))
            {
                issued.paths.remove(path);
            }
        }
        if issued
            .barrier
            .as_ref()
            .is_some_and(|barrier| barrier.same_channel(&self.marker))
        {
            issued.barrier = None;
        }
    }
}

/// Waits until the operation `tail` stands for is over.
async fn wait_over(mut tail: watch::Receiver<()>) {
    // Nothing is ever sent: this returns once the sender is dropped.
    while tail.changed().await.is_ok() {}
}

fn lock(issued: &Mutex<Issued>) -> std::sync::MutexGuard<'_, Issued> {
    issued.lock().unwrap_or_else(PoisonError::into_inner)
}

#[cfg(test)]
mod tests {
    //! The cases of `test/dsync_core/agent/request_window_test.dart`, and
    //! the pipelining cases of `remote_agent_test.dart` that are the
    //! window's.

    use std::future::Future;
    use std::sync::atomic::{AtomicUsize, Ordering};
    use std::time::Duration;

    use tokio::sync::oneshot;
    use tokio::task::JoinHandle;

    use super::*;

    const DEADLINE: Duration = Duration::from_secs(5);

    async fn with_deadline<T>(label: &str, work: impl Future<Output = T>) -> T {
        tokio::time::timeout(DEADLINE, work)
            .await
            .unwrap_or_else(|_| panic!("{label} did not finish within {DEADLINE:?}"))
    }

    fn path(text: &str) -> RelPath {
        RelPath::parse(text).unwrap()
    }

    /// Lets every task that can run, run.
    async fn settle() {
        for _ in 0..50 {
            tokio::task::yield_now().await;
        }
    }

    /// An operation that, once admitted, records itself in `log` and holds
    /// its slot until `release` fires.
    struct Held {
        release: oneshot::Sender<()>,
        task: JoinHandle<()>,
    }

    fn hold(
        window: &Arc<RequestWindow>,
        paths: Option<Vec<&str>>,
        name: &'static str,
        log: &Arc<Mutex<Vec<&'static str>>>,
    ) -> Held {
        let (release, released) = oneshot::channel::<()>();
        let window = window.clone();
        let log = log.clone();
        let paths: Option<Vec<RelPath>> = paths.map(|p| p.into_iter().map(path).collect());
        let task = tokio::spawn(async move {
            let _slot = match paths {
                Some(paths) => window.enter(paths).await,
                None => window.barrier().await,
            };
            log.lock().unwrap().push(name);
            let _ = released.await;
        });
        Held { release, task }
    }

    impl Held {
        async fn finish(self) {
            let _ = self.release.send(());
            with_deadline("an operation's end", self.task)
                .await
                .unwrap();
        }
    }

    fn logged(log: &Arc<Mutex<Vec<&'static str>>>) -> Vec<&'static str> {
        log.lock().unwrap().clone()
    }

    #[tokio::test]
    async fn admits_at_most_size_operations_at_once() {
        let window = Arc::new(RequestWindow::new(3));
        let running = Arc::new(AtomicUsize::new(0));
        let peak = Arc::new(AtomicUsize::new(0));
        let tasks: Vec<_> = (0..10)
            .map(|n| {
                let (window, running, peak) = (window.clone(), running.clone(), peak.clone());
                tokio::spawn(async move {
                    let _slot = window.enter([path(&format!("f{n}"))]).await;
                    let now = running.fetch_add(1, Ordering::SeqCst) + 1;
                    peak.fetch_max(now, Ordering::SeqCst);
                    tokio::task::yield_now().await;
                    running.fetch_sub(1, Ordering::SeqCst);
                })
            })
            .collect();
        for task in tasks {
            with_deadline("windowed op", task).await.unwrap();
        }
        assert_eq!(peak.load(Ordering::SeqCst), 3);
    }

    #[tokio::test]
    async fn a_failed_or_cancelled_operation_gives_its_slot_back() {
        let window = Arc::new(RequestWindow::new(1));
        let failing = {
            let window = window.clone();
            tokio::spawn(async move {
                let _slot = window.enter([path("a")]).await;
                panic!("the operation failed");
            })
        };
        assert!(with_deadline("failing op", failing).await.is_err());
        // A caller cancelled while waiting on its path releases the path.
        let held = window.enter([path("b")]).await;
        let waiting = window.enter([path("b")]);
        drop(tokio::time::timeout(Duration::from_millis(1), waiting).await);
        drop(held);
        drop(with_deadline("the next op", window.enter([path("a"), path("b")])).await);
    }

    #[tokio::test]
    async fn operations_on_one_path_run_one_at_a_time_in_issue_order() {
        let window = Arc::new(RequestWindow::new(8));
        let log = Arc::new(Mutex::new(Vec::new()));
        let first = hold(&window, Some(vec!["p"]), "first", &log);
        settle().await;
        let second = hold(&window, Some(vec!["p"]), "second", &log);
        let third = hold(&window, Some(vec!["p"]), "third", &log);
        let other = hold(&window, Some(vec!["q"]), "other", &log);
        settle().await;
        assert_eq!(logged(&log), ["first", "other"]);
        first.finish().await;
        settle().await;
        assert_eq!(logged(&log), ["first", "other", "second"]);
        second.finish().await;
        third.finish().await;
        other.finish().await;
        assert_eq!(logged(&log), ["first", "other", "second", "third"]);
    }

    #[tokio::test]
    async fn a_batch_waits_behind_every_path_it_carries() {
        let window = Arc::new(RequestWindow::new(8));
        let log = Arc::new(Mutex::new(Vec::new()));
        let a = hold(&window, Some(vec!["a"]), "a", &log);
        let b = hold(&window, Some(vec!["b"]), "b", &log);
        settle().await;
        // The same path twice in one batch must not wait on itself.
        let batch = hold(&window, Some(vec!["a", "b", "a"]), "batch", &log);
        settle().await;
        a.finish().await;
        settle().await;
        assert_eq!(logged(&log), ["a", "b"]);
        b.finish().await;
        settle().await;
        assert_eq!(logged(&log), ["a", "b", "batch"]);
        batch.finish().await;
    }

    #[tokio::test]
    async fn an_operation_waiting_on_its_path_does_not_hold_a_slot() {
        let window = Arc::new(RequestWindow::new(2));
        let log = Arc::new(Mutex::new(Vec::new()));
        let first = hold(&window, Some(vec!["p"]), "first", &log);
        settle().await;
        let queued = hold(&window, Some(vec!["p"]), "queued", &log);
        let other = hold(&window, Some(vec!["q"]), "other", &log);
        settle().await;
        // `queued` waits on `p`; `other` got the second slot.
        assert_eq!(logged(&log), ["first", "other"]);
        first.finish().await;
        queued.finish().await;
        other.finish().await;
    }

    #[tokio::test]
    async fn a_barrier_drains_the_window_before_running() {
        let window = Arc::new(RequestWindow::new(4));
        let log = Arc::new(Mutex::new(Vec::new()));
        let a = hold(&window, Some(vec!["a"]), "a", &log);
        let b = hold(&window, Some(vec!["b"]), "b", &log);
        settle().await;
        let barrier = hold(&window, None, "barrier", &log);
        settle().await;
        assert_eq!(logged(&log), ["a", "b"]);
        a.finish().await;
        settle().await;
        assert_eq!(logged(&log), ["a", "b"]);
        b.finish().await;
        settle().await;
        assert_eq!(logged(&log), ["a", "b", "barrier"]);
        barrier.finish().await;
    }

    #[tokio::test]
    async fn a_barrier_holds_everything_issued_after_it() {
        let window = Arc::new(RequestWindow::new(4));
        let log = Arc::new(Mutex::new(Vec::new()));
        let a = hold(&window, Some(vec!["a"]), "a", &log);
        settle().await;
        let barrier = hold(&window, None, "barrier", &log);
        settle().await;
        let later = hold(&window, Some(vec!["z"]), "later", &log);
        let later_barrier = hold(&window, None, "later barrier", &log);
        settle().await;
        assert_eq!(logged(&log), ["a"]);
        a.finish().await;
        settle().await;
        assert_eq!(logged(&log), ["a", "barrier"]);
        barrier.finish().await;
        settle().await;
        assert_eq!(logged(&log), ["a", "barrier", "later"]);
        later.finish().await;
        later_barrier.finish().await;
        assert_eq!(logged(&log), ["a", "barrier", "later", "later barrier"]);
    }

    #[tokio::test]
    async fn a_barrier_waits_for_an_operation_still_queued_behind_its_own_path() {
        let window = Arc::new(RequestWindow::new(4));
        let log = Arc::new(Mutex::new(Vec::new()));
        let first = hold(&window, Some(vec!["p"]), "first", &log);
        settle().await;
        let queued = hold(&window, Some(vec!["p"]), "queued", &log);
        settle().await;
        let barrier = hold(&window, None, "barrier", &log);
        settle().await;
        first.finish().await;
        settle().await;
        assert_eq!(logged(&log), ["first", "queued"]);
        queued.finish().await;
        settle().await;
        assert_eq!(logged(&log), ["first", "queued", "barrier"]);
        barrier.finish().await;
    }

    #[tokio::test]
    async fn a_failed_barrier_releases_the_window() {
        let window = Arc::new(RequestWindow::new(2));
        let failing = {
            let window = window.clone();
            tokio::spawn(async move {
                let _slot = window.barrier().await;
                panic!("the barrier failed");
            })
        };
        assert!(with_deadline("failing barrier", failing).await.is_err());
        drop(with_deadline("the next op", window.enter([path("a")])).await);
        drop(with_deadline("the next barrier", window.barrier()).await);
    }

    #[tokio::test]
    async fn a_slot_moved_elsewhere_is_held_until_it_is_dropped() {
        // A read's slot lives in its body's forwarding task, for as long as
        // the body is consumed.
        let window = Arc::new(RequestWindow::new(1));
        let slot = window.enter([path("streamed")]).await;
        let (drop_it, dropped) = oneshot::channel::<()>();
        let holder = tokio::spawn(async move {
            let _slot = slot;
            let _ = dropped.await;
        });
        let next = window.enter([path("other")]);
        tokio::pin!(next);
        assert!(
            tokio::time::timeout(Duration::from_millis(20), &mut next)
                .await
                .is_err()
        );
        drop_it.send(()).unwrap();
        drop(with_deadline("the next op", next).await);
        holder.await.unwrap();
    }
}
