//! Where a replica's writers spent their time (SPEC §17): per stage of
//! writing a file, plus how long files queued for a writer and how many
//! writers were busy on average. Monotonic clock only; each writer keeps
//! its own and the pool adds them up when asked.
//!
//! Carried over from the spike's measured writer (plan D3, D11), with the
//! mode and closing-stat stages the Dart write path timed and without the
//! per-thread CPU clock, which needs `libc` and belongs to the run metrics.

use std::fmt;
use std::time::Duration;

/// One step of writing a file, in the order a file goes through them.
#[derive(Clone, Copy, PartialEq, Eq, Debug, serde::Serialize, serde::Deserialize)]
pub enum Stage {
    /// Creating the parent folders, once per folder per session.
    Mkdir,
    /// Reading what is at the target already, to check it against the
    /// scan (SPEC §7.6).
    Probe,
    /// Creating the temp the bytes land in (SPEC §7.2).
    Create,
    /// Waiting for the file's bytes to arrive; like [`Stage::Write`], once
    /// per chunk, not per file.
    Wait,
    Write,
    Mtime,
    /// Setting the permission bits, or deciding once not to (SPEC §7.4).
    Mode,
    /// Syncing the bytes to disk and closing the handle (SPEC §7.2).
    Close,
    /// Renaming the temp onto the target and syncing its folder.
    Rename,
    /// Reading back what actually landed (SPEC §7.4).
    Stat,
}

impl Stage {
    pub const ALL: [Stage; 10] = [
        Stage::Mkdir,
        Stage::Probe,
        Stage::Create,
        Stage::Wait,
        Stage::Write,
        Stage::Mtime,
        Stage::Mode,
        Stage::Close,
        Stage::Rename,
        Stage::Stat,
    ];

    pub fn name(self) -> &'static str {
        match self {
            Stage::Mkdir => "mkdir",
            Stage::Probe => "probe",
            Stage::Create => "create",
            Stage::Wait => "wait",
            Stage::Write => "write",
            Stage::Mtime => "mtime",
            Stage::Mode => "mode",
            Stage::Close => "close",
            Stage::Rename => "rename",
            Stage::Stat => "stat",
        }
    }
}

impl fmt::Display for Stage {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(self.name())
    }
}

/// How many times one stage ran and how long it took in all.
#[derive(Clone, Copy, Default, Debug, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
pub struct StageTime {
    pub count: u64,
    pub total: Duration,
}

impl StageTime {
    /// None when the stage never ran.
    pub fn mean(&self) -> Option<Duration> {
        (self.count > 0).then(|| mean(self.total, self.count))
    }
}

#[derive(Clone, Debug, Default, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
pub struct WriteStats {
    pub writers: usize,
    /// Files written to the end and landed.
    pub files: u64,
    stages: [StageTime; Stage::ALL.len()],
    /// Summed over files: from a writer taking the file to the file done.
    pub busy: Duration,
    /// Summed over files: from the write being submitted to a writer
    /// taking it.
    pub queue_wait: Duration,
}

impl WriteStats {
    /// Empty stats for one writer to fill in.
    pub fn one_writer() -> Self {
        WriteStats {
            writers: 1,
            ..Default::default()
        }
    }

    pub fn record(&mut self, stage: Stage, took: Duration) {
        let time = &mut self.stages[stage as usize];
        time.count += 1;
        time.total += took;
    }

    pub fn stage(&self, stage: Stage) -> StageTime {
        self.stages[stage as usize]
    }

    /// Every stage's time, summed: the writers' own work and waits.
    pub fn staged(&self) -> Duration {
        self.stages.iter().map(|time| time.total).sum()
    }

    /// Every writer's stats added up.
    pub fn total<'a>(parts: impl IntoIterator<Item = &'a WriteStats>) -> WriteStats {
        let mut all = WriteStats::default();
        for part in parts {
            all.absorb(part);
        }
        all
    }

    /// Adds `other` in: another writer's stats, or one file's.
    pub fn absorb(&mut self, other: &WriteStats) {
        self.writers += other.writers;
        self.files += other.files;
        for (mine, theirs) in self.stages.iter_mut().zip(&other.stages) {
            mine.count += theirs.count;
            mine.total += theirs.total;
        }
        self.busy += other.busy;
        self.queue_wait += other.queue_wait;
    }

    /// The mean number of writers busy with a file over `wall`.
    pub fn writers_busy(&self, wall: Duration) -> f64 {
        self.busy.as_secs_f64() / wall.as_secs_f64().max(1e-6)
    }

    /// None with no files.
    pub fn mean_queue_wait(&self) -> Option<Duration> {
        (self.files > 0).then(|| mean(self.queue_wait, self.files))
    }

    /// Lines for a report: the stages, then the pool, over a transfer that
    /// took `wall`.
    pub fn report(&self, wall: Duration) -> Vec<String> {
        let mut stages = String::from("stages (count, mean ms, total s):");
        for stage in Stage::ALL {
            let time = self.stage(stage);
            if let Some(mean) = time.mean() {
                stages.push_str(&format!(
                    "  {stage} {} {:.3} {:.3}",
                    time.count,
                    ms(mean),
                    time.total.as_secs_f64()
                ));
            }
        }
        vec![
            stages,
            format!(
                "writers {}  busy {:.2}  queue wait mean {:.3} ms total {:.3} s",
                self.writers,
                self.writers_busy(wall),
                self.mean_queue_wait().map_or(0.0, ms),
                self.queue_wait.as_secs_f64()
            ),
        ]
    }
}

fn mean(total: Duration, count: u64) -> Duration {
    Duration::from_nanos((total.as_nanos() / u128::from(count)) as u64)
}

fn ms(duration: Duration) -> f64 {
    duration.as_secs_f64() * 1000.0
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn totals_add_up_and_average_per_run() {
        let mut one = WriteStats {
            writers: 1,
            files: 2,
            busy: Duration::from_millis(300),
            queue_wait: Duration::from_millis(10),
            ..Default::default()
        };
        one.record(Stage::Create, Duration::from_millis(20));
        one.record(Stage::Create, Duration::from_millis(40));
        let mut two = WriteStats {
            writers: 1,
            files: 1,
            busy: Duration::from_millis(100),
            queue_wait: Duration::from_millis(20),
            ..Default::default()
        };
        two.record(Stage::Create, Duration::from_millis(30));
        two.record(Stage::Stat, Duration::from_millis(5));

        let all = WriteStats::total([&one, &two]);

        assert_eq!(all.writers, 2);
        assert_eq!(all.files, 3);
        let create = all.stage(Stage::Create);
        assert_eq!(create.count, 3);
        assert_eq!(create.mean(), Some(Duration::from_millis(30)));
        assert_eq!(all.stage(Stage::Rename).mean(), None);
        assert_eq!(all.staged(), Duration::from_millis(95));
        assert_eq!(all.writers_busy(Duration::from_millis(200)), 2.0);
        assert_eq!(all.mean_queue_wait(), Some(Duration::from_millis(10)));
    }

    #[test]
    fn the_report_lists_only_stages_that_ran() {
        let mut stats = WriteStats::one_writer();
        stats.files = 1;
        stats.record(Stage::Write, Duration::from_millis(2));

        let report = stats.report(Duration::from_millis(10));

        assert_eq!(
            report[0],
            "stages (count, mean ms, total s):  write 1 2.000 0.002"
        );
        assert!(report[1].starts_with("writers 1  busy"), "{}", report[1]);
    }
}
