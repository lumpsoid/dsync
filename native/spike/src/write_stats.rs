//! Where a server's writers spent their time: per stage of writing a file,
//! plus how long files queued for a writer, how many writers were busy on
//! average, and the writer threads' own CPU. Monotonic clock only; each
//! writer keeps its own and the pool adds them up at the end.

use std::fmt;
use std::time::Duration;

/// One step of writing a file, in the order a file goes through them.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Stage {
    /// Reading what is at the target already (SPEC §7.2's WriteTarget).
    Probe,
    /// Creating a fresh file's parent folders, once per folder per transfer.
    Mkdir,
    /// Creating a file that was not there (or a temp beside one, see
    /// [Stage::Rename]).
    Create,
    /// Opening an existing file to overwrite it in place (truncating).
    Open,
    /// Waiting for the file's bytes to arrive from the socket; like
    /// [Stage::Write], once per chunk (up to 256 KiB), not per file.
    Wait,
    Write,
    Mtime,
    /// Closing the handle.
    Close,
    /// Renaming a temp over a target that could not be written in place.
    Rename,
}

impl Stage {
    pub const ALL: [Stage; 9] = [
        Stage::Probe,
        Stage::Mkdir,
        Stage::Create,
        Stage::Open,
        Stage::Wait,
        Stage::Write,
        Stage::Mtime,
        Stage::Close,
        Stage::Rename,
    ];

    pub fn name(self) -> &'static str {
        match self {
            Stage::Mkdir => "mkdir",
            Stage::Probe => "probe",
            Stage::Create => "create",
            Stage::Open => "open",
            Stage::Wait => "wait",
            Stage::Write => "write",
            Stage::Mtime => "mtime",
            Stage::Close => "close",
            Stage::Rename => "rename",
        }
    }
}

impl fmt::Display for Stage {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(self.name())
    }
}

/// How many times one stage ran and how long it took in all.
#[derive(Clone, Copy, Default, Debug, PartialEq)]
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

#[derive(Clone, Debug, Default)]
pub struct WriteStats {
    pub writers: usize,
    /// Files written to the end, mtime set.
    pub files: u64,
    stages: [StageTime; Stage::ALL.len()],
    /// Summed over files: from a writer taking the file to the file done.
    pub busy: Duration,
    /// Summed over files: from the file's header arriving to a writer taking
    /// it.
    pub queue_wait: Duration,
    /// The writer threads' CPU, summed; None where the platform has no
    /// per-thread CPU clock.
    pub writer_cpu: Option<Duration>,
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

    /// Every writer's stats added up. The writer CPU is known only if every
    /// writer's is.
    pub fn total(parts: &[WriteStats]) -> WriteStats {
        let mut all = WriteStats {
            writer_cpu: Some(Duration::ZERO),
            ..Default::default()
        };
        for part in parts {
            all.writers += part.writers;
            all.files += part.files;
            for (mine, theirs) in all.stages.iter_mut().zip(&part.stages) {
                mine.count += theirs.count;
                mine.total += theirs.total;
            }
            all.busy += part.busy;
            all.queue_wait += part.queue_wait;
            all.writer_cpu = all.writer_cpu.zip(part.writer_cpu).map(|(a, b)| a + b);
        }
        all
    }

    /// The mean number of writers busy with a file over [wall].
    pub fn writers_busy(&self, wall: Duration) -> f64 {
        self.busy.as_secs_f64() / wall.as_secs_f64().max(1e-6)
    }

    /// None with no files.
    pub fn mean_queue_wait(&self) -> Option<Duration> {
        (self.files > 0).then(|| mean(self.queue_wait, self.files))
    }

    /// The process CPU the writer threads did not spend; None if either
    /// reading is missing.
    pub fn other_cpu(&self, process_cpu: Option<Duration>) -> Option<Duration> {
        process_cpu
            .zip(self.writer_cpu)
            .map(|(all, writers)| all.saturating_sub(writers))
    }

    /// Lines for a report: the stages, then the pool. [wall] and
    /// [process_cpu] are the transfer's (TransferMetrics).
    pub fn report(&self, wall: Duration, process_cpu: Option<Duration>) -> Vec<String> {
        let mut lines = Vec::new();
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
        lines.push(stages);
        lines.push(format!(
            "writers {}  busy {:.2}  queue wait mean {:.3} ms total {:.3} s",
            self.writers,
            self.writers_busy(wall),
            self.mean_queue_wait().map_or(0.0, ms),
            self.queue_wait.as_secs_f64()
        ));
        let seconds = |cpu: Option<Duration>| {
            cpu.map_or("-".to_string(), |c| format!("{:.3}", c.as_secs_f64()))
        };
        lines.push(format!(
            "cpu writers {} s  rest {} s",
            seconds(self.writer_cpu),
            seconds(self.other_cpu(process_cpu))
        ));
        lines
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
            writer_cpu: Some(Duration::from_millis(40)),
            ..Default::default()
        };
        one.record(Stage::Create, Duration::from_millis(20));
        one.record(Stage::Create, Duration::from_millis(40));
        let mut two = WriteStats {
            writers: 1,
            files: 1,
            busy: Duration::from_millis(100),
            queue_wait: Duration::from_millis(20),
            writer_cpu: Some(Duration::from_millis(10)),
            ..Default::default()
        };
        two.record(Stage::Create, Duration::from_millis(30));

        let all = WriteStats::total(&[one, two]);

        assert_eq!(all.writers, 2);
        assert_eq!(all.files, 3);
        let create = all.stage(Stage::Create);
        assert_eq!(create.count, 3);
        assert_eq!(create.mean(), Some(Duration::from_millis(30)));
        assert_eq!(all.stage(Stage::Rename).mean(), None);
        assert_eq!(all.writers_busy(Duration::from_millis(200)), 2.0);
        assert_eq!(all.mean_queue_wait(), Some(Duration::from_millis(10)));
        assert_eq!(all.writer_cpu, Some(Duration::from_millis(50)));
    }
}
