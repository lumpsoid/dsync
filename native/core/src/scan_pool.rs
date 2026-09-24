//! The scan's bounded pool of blocking threads (plan D3): at most `jobs`
//! workers pulling from one shared queue, in queue order. The scan's stats
//! and hashes run on it; file I/O never goes through an async runtime.

use std::sync::Mutex;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::thread;

use dsync_domain::Jobs;

/// `work` over every item on at most `jobs` scoped threads, results in
/// item order. Each worker takes the next item not yet taken, so the queue
/// drains front first whatever the item costs; each gets its own `state`
/// (a read buffer) for its lifetime rather than one per item.
///
/// No worker outlives the call, and a panic in one is re-raised here.
pub(crate) fn run<T, S, R>(
    jobs: Jobs,
    items: &[T],
    state: impl Fn() -> S + Sync,
    work: impl Fn(&mut S, &T) -> R + Sync,
) -> Vec<R>
where
    T: Sync,
    R: Send,
{
    let next = AtomicUsize::new(0);
    let done: Mutex<Vec<(usize, R)>> = Mutex::new(Vec::with_capacity(items.len()));
    let workers = jobs.get().min(items.len());
    thread::scope(|scope| {
        for _ in 0..workers {
            scope.spawn(|| {
                let mut own = state();
                let mut finished = Vec::new();
                loop {
                    let index = next.fetch_add(1, Ordering::Relaxed);
                    let Some(item) = items.get(index) else {
                        break;
                    };
                    finished.push((index, work(&mut own, item)));
                }
                done.lock()
                    .unwrap_or_else(|poisoned| poisoned.into_inner())
                    .extend(finished);
            });
        }
    });
    let mut done = done
        .into_inner()
        .unwrap_or_else(|poisoned| poisoned.into_inner());
    done.sort_unstable_by_key(|(index, _)| *index);
    done.into_iter().map(|(_, result)| result).collect()
}

#[cfg(test)]
mod tests {
    use std::sync::Condvar;
    use std::time::Duration;

    use super::*;

    fn jobs(count: i64) -> Jobs {
        Jobs::new(count).unwrap()
    }

    /// How many workers were inside `work` at once, at most. Each waits
    /// (bounded) for `target` to be inside together, so a pool running
    /// fewer threads shows up as a lower peak, not as a hang.
    fn peak_concurrency(pool: Jobs, items: usize, target: usize, patience: Duration) -> usize {
        let inside = Mutex::new((0usize, 0usize)); // (now, peak)
        let changed = Condvar::new();
        let items: Vec<usize> = (0..items).collect();
        run(
            pool,
            &items,
            || (),
            |(), _| {
                let mut guard = inside.lock().unwrap();
                guard.0 += 1;
                guard.1 = guard.1.max(guard.0);
                changed.notify_all();
                let (mut guard, _) = changed
                    .wait_timeout_while(guard, patience, |(_, peak)| *peak < target)
                    .unwrap();
                guard.0 -= 1;
            },
        );
        inside.into_inner().unwrap().1
    }

    #[test]
    fn runs_exactly_jobs_workers_at_once() {
        // The patience is a deadline, never reached when the pool is right.
        let deadline = Duration::from_secs(5);
        assert_eq!(peak_concurrency(jobs(4), 16, 4, deadline), 4);
        assert_eq!(peak_concurrency(jobs(3), 16, 3, deadline), 3);
        // Never more than asked, however long a worker waits for company.
        let brief = Duration::from_millis(100);
        assert_eq!(peak_concurrency(jobs(2), 4, 3, brief), 2);
    }

    #[test]
    fn never_more_workers_than_items() {
        assert_eq!(
            peak_concurrency(jobs(8), 2, 8, Duration::from_millis(100)),
            2
        );
    }

    #[test]
    fn drains_the_queue_front_first() {
        let order = Mutex::new(Vec::new());
        let items = [9u64, 7, 5, 3, 1];
        run(
            jobs(1),
            &items,
            || (),
            |(), item| order.lock().unwrap().push(*item),
        );
        assert_eq!(order.into_inner().unwrap(), items);
    }

    #[test]
    fn results_come_back_in_item_order_with_state_per_worker() {
        let items: Vec<u64> = (0..100).collect();
        let states = AtomicUsize::new(0);
        let doubled = run(
            jobs(4),
            &items,
            || states.fetch_add(1, Ordering::Relaxed),
            |_, item| item * 2,
        );
        assert_eq!(doubled, items.iter().map(|i| i * 2).collect::<Vec<_>>());
        assert!(states.into_inner() <= 4);
    }

    #[test]
    fn an_empty_queue_starts_nothing() {
        let results: Vec<()> = run(jobs(4), &[] as &[u8], || panic!("no worker"), |(), _| ());
        assert!(results.is_empty());
    }
}
