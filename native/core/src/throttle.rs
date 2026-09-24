//! At most one event per interval: the first is let through at once, later
//! ones only once the interval has passed since the last one let through.

use std::time::{Duration, Instant};

/// The progress event rate the heads see: at most one per 50 ms.
pub const PROGRESS_INTERVAL: Duration = Duration::from_millis(50);

pub struct Throttle {
    interval: Duration,
    last: Option<Instant>,
}

impl Throttle {
    pub fn new(interval: Duration) -> Self {
        Throttle {
            interval,
            last: None,
        }
    }

    /// Whether an event at [now] goes out; if it does, the next one waits a
    /// full interval from [now].
    pub fn pass(&mut self, now: Instant) -> bool {
        let due = self
            .last
            .is_none_or(|last| now.duration_since(last) >= self.interval);
        if due {
            self.last = Some(now);
        }
        due
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn lets_the_first_through_then_one_per_interval() {
        let start = Instant::now();
        let at = |ms| start + Duration::from_millis(ms);
        let mut throttle = Throttle::new(Duration::from_millis(50));
        let passed: Vec<u64> = [0, 10, 49, 50, 60, 99, 100, 250]
            .into_iter()
            .filter(|&ms| throttle.pass(at(ms)))
            .collect();
        assert_eq!(passed, vec![0, 50, 100, 250]);
    }
}
