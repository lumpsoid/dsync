//! One run's measurements (SPEC §17, plan D11) and their `--timings`
//! text. Instrumentation only: nothing in the engine reads these.
//!
//! Kept from the Dart report: the phase spans, per replica and per
//! operation the count, total, mean and max wall time, file content moved,
//! and the writers' stage timings (a remote replica's as its server
//! reported them on `unlock`). Added: the process's CPU time and its cost
//! per MiB moved. Dropped: every figure that diagnosed the Dart event loop.

use std::collections::BTreeMap;
use std::fmt::Write as _;
use std::time::Duration;

use crate::metric_format::{format_bytes, format_count, format_duration};
use crate::side::Side;
use crate::write_stats::WriteStats;

const MIB: f64 = 1024.0 * 1024.0;

/// SPEC §13's flow, as §17 divides it.
#[derive(Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash, Debug)]
pub enum RunPhase {
    /// Both `hello`s.
    Connect,
    Lock,
    /// All three phases of the exchange (SPEC §6.1), both sides at once.
    Scan,
    Reconcile,
    /// The decider's turn: think time on an interactive head, so outside
    /// the run's total.
    Present,
    Apply,
    Compact,
    Unlock,
    /// Closing both connections.
    Disconnect,
}

impl RunPhase {
    pub const ALL: [RunPhase; 9] = [
        RunPhase::Connect,
        RunPhase::Lock,
        RunPhase::Scan,
        RunPhase::Reconcile,
        RunPhase::Present,
        RunPhase::Apply,
        RunPhase::Compact,
        RunPhase::Unlock,
        RunPhase::Disconnect,
    ];

    pub fn name(self) -> &'static str {
        match self {
            RunPhase::Connect => "connect",
            RunPhase::Lock => "lock",
            RunPhase::Scan => "scan",
            RunPhase::Reconcile => "reconcile",
            RunPhase::Present => "present",
            RunPhase::Apply => "apply",
            RunPhase::Compact => "compact",
            RunPhase::Unlock => "unlock",
            RunPhase::Disconnect => "disconnect",
        }
    }
}

/// One operation of the replica contract, as a report row. The three
/// scan phases are one row (SPEC §17).
#[derive(Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash, Debug)]
pub enum ReplicaOp {
    Hello,
    Lock,
    Unlock,
    CreateRoot,
    Scan,
    Read,
    Write,
    Stage,
    TakeLanded,
    Delete,
    RemoveEmptyDirs,
    Commit,
    Compact,
    Close,
}

impl ReplicaOp {
    /// An operation whose time is spent waiting on the replica, not
    /// keeping it busy: `take_landed` waits for a staged copy to land, so
    /// its time is the landings' lag, already in the writes it waits on.
    pub fn is_wait(self) -> bool {
        matches!(self, ReplicaOp::TakeLanded)
    }

    pub fn name(self) -> &'static str {
        match self {
            ReplicaOp::Hello => "hello",
            ReplicaOp::Lock => "lock",
            ReplicaOp::Unlock => "unlock",
            ReplicaOp::CreateRoot => "createRoot",
            ReplicaOp::Scan => "scan",
            ReplicaOp::Read => "read",
            ReplicaOp::Write => "write",
            ReplicaOp::Stage => "stage",
            ReplicaOp::TakeLanded => "takeLanded",
            ReplicaOp::Delete => "delete",
            ReplicaOp::RemoveEmptyDirs => "removeEmptyDirs",
            ReplicaOp::Commit => "commit",
            ReplicaOp::Compact => "compact",
            ReplicaOp::Close => "close",
        }
    }
}

/// Calls of one operation: how many, and their wall time.
#[derive(Clone, Copy, PartialEq, Eq, Debug, Default)]
pub struct OpStats {
    pub count: u64,
    pub total: Duration,
    pub max: Duration,
}

impl OpStats {
    pub fn record(&mut self, took: Duration) {
        self.count += 1;
        self.total += took;
        self.max = self.max.max(took);
    }

    /// None when the operation never ran.
    pub fn mean(&self) -> Option<Duration> {
        (self.count > 0).then(|| self.total.div_f64(self.count as f64))
    }
}

/// One replica's share of a run.
#[derive(Clone, PartialEq, Debug, Default)]
pub struct ReplicaMetrics {
    pub ops: BTreeMap<ReplicaOp, OpStats>,
    /// File content read from and written to this replica.
    pub content_bytes: u64,
    /// Its writers' stage timings: the local pool's, or what a remote
    /// replica's server reported on `unlock`. None when it never said.
    pub write_stats: Option<WriteStats>,
}

impl ReplicaMetrics {
    pub fn record(&mut self, op: ReplicaOp, took: Duration) {
        self.ops.entry(op).or_default().record(took);
    }

    pub fn op_count(&self) -> u64 {
        self.ops.values().map(|stats| stats.count).sum()
    }
}

/// A whole run's measurements.
#[derive(Clone, PartialEq, Debug, Default)]
pub struct RunMetrics {
    /// Each phase the run reached; a phase entered twice (one `hello` per
    /// side) is summed.
    pub phases: BTreeMap<RunPhase, Duration>,
    pub a: ReplicaMetrics,
    pub b: ReplicaMetrics,
    /// File content the applied copies moved.
    pub transferred_bytes: u64,
    /// This process's CPU time over the run, user plus system; None where
    /// the platform does not say.
    pub cpu: Option<Duration>,
    /// How far into the apply the last staged copy's stage answered: when
    /// the download was done, whatever the landings still had to do. None
    /// when nothing staged.
    pub received: Option<Duration>,
}

impl RunMetrics {
    pub fn add_phase(&mut self, phase: RunPhase, took: Duration) {
        *self.phases.entry(phase).or_default() += took;
    }

    pub fn replica(&self, side: Side) -> &ReplicaMetrics {
        match side {
            Side::A => &self.a,
            Side::B => &self.b,
        }
    }

    pub fn replica_mut(&mut self, side: Side) -> &mut ReplicaMetrics {
        match side {
            Side::A => &mut self.a,
            Side::B => &mut self.b,
        }
    }

    /// SPEC §17's run total: every phase but `present`, which is how long
    /// someone took to answer.
    pub fn total(&self) -> Duration {
        self.phases
            .iter()
            .filter(|(phase, _)| **phase != RunPhase::Present)
            .map(|(_, took)| *took)
            .sum()
    }

    /// CPU time per MiB moved; None without a CPU reading or with nothing
    /// moved.
    pub fn cpu_per_mib(&self) -> Option<Duration> {
        let cpu = self.cpu?;
        (self.transferred_bytes > 0).then(|| cpu.div_f64(self.transferred_bytes as f64 / MIB))
    }

    /// The `--timings` report. Its head - the `run:`, `cpu:` and
    /// `received:` lines and the phase table - is what
    /// `benchmark/pairs/run_timings.dart` parses.
    pub fn render(&self) -> String {
        let mut out = String::new();
        let ops = self.a.op_count() + self.b.op_count();
        let _ = writeln!(
            out,
            "run: {} total, {} replica operations, {} of file content moved",
            format_duration(self.total()),
            format_count(ops),
            format_bytes(self.transferred_bytes)
        );
        let cpu = match (self.cpu, self.cpu_per_mib()) {
            (None, _) => "—".to_owned(),
            (Some(cpu), None) => format_duration(cpu),
            (Some(cpu), Some(per)) => {
                format!("{}, {} per MiB", format_duration(cpu), format_duration(per))
            }
        };
        let _ = writeln!(out, "cpu: {cpu}");
        if let Some(received) = self.received {
            let _ = writeln!(out, "received: {} into apply", format_duration(received));
        }
        let _ = writeln!(out);
        let _ = writeln!(out, "phases");
        for phase in RunPhase::ALL {
            let took = self
                .phases
                .get(&phase)
                .map_or_else(|| "—".to_owned(), |took| format_duration(*took));
            let _ = writeln!(out, "  {:<12}{took:>10}", phase.name());
        }
        let wall = self.phases.get(&RunPhase::Apply).copied();
        for side in Side::BOTH {
            render_replica(&mut out, side, self.replica(side), wall);
        }
        out
    }
}

fn render_op(out: &mut String, op: ReplicaOp, stats: &OpStats) {
    let mean = stats.mean().map_or_else(|| "—".to_owned(), format_duration);
    let _ = writeln!(
        out,
        "  {:<20}{:>8}{:>10}{mean:>10}{:>10}",
        op.name(),
        format_count(stats.count),
        format_duration(stats.total),
        format_duration(stats.max)
    );
}

fn render_replica(out: &mut String, side: Side, replica: &ReplicaMetrics, wall: Option<Duration>) {
    let _ = writeln!(out);
    let _ = writeln!(
        out,
        "replica {side} — {} operations, {} of file content",
        format_count(replica.op_count()),
        format_bytes(replica.content_bytes)
    );
    let _ = writeln!(
        out,
        "  {:<20}{:>8}{:>10}{:>10}{:>10}",
        "operation", "count", "total", "mean", "max"
    );
    let (waits, mut work): (Vec<_>, Vec<_>) = replica.ops.iter().partition(|(op, _)| op.is_wait());
    work.sort_by_key(|(_, stats)| std::cmp::Reverse(stats.total));
    for (op, stats) in work {
        render_op(out, *op, stats);
    }
    if !waits.is_empty() {
        let _ = writeln!(out, "  waits, not busy time");
        for (op, stats) in waits {
            render_op(out, *op, stats);
        }
    }
    if let (Some(stats), Some(wall)) = (&replica.write_stats, wall)
        && stats.files > 0
    {
        for line in stats.report(wall) {
            let _ = writeln!(out, "  write {line}");
        }
    }
}

#[cfg(test)]
mod tests {
    //! The kept cases of `run_metrics_report_test.dart`: the served write
    //! stages print when there were any and not otherwise; plus the head
    //! the bench parser reads.

    use super::*;
    use crate::write_stats::Stage;

    fn metrics() -> RunMetrics {
        let mut metrics = RunMetrics::default();
        metrics.add_phase(RunPhase::Connect, Duration::from_millis(2));
        metrics.add_phase(RunPhase::Connect, Duration::from_millis(1));
        metrics.add_phase(RunPhase::Present, Duration::from_secs(30));
        metrics.add_phase(RunPhase::Apply, Duration::from_millis(500));
        metrics.a.record(ReplicaOp::Write, Duration::from_millis(4));
        metrics.a.record(ReplicaOp::Write, Duration::from_millis(2));
        metrics
            .b
            .record(ReplicaOp::Read, Duration::from_micros(300));
        metrics.transferred_bytes = 2 * 1024 * 1024;
        metrics
    }

    #[test]
    fn the_total_leaves_out_present_and_sums_a_phase_entered_twice() {
        let metrics = metrics();
        assert_eq!(metrics.phases[&RunPhase::Connect], Duration::from_millis(3));
        assert_eq!(metrics.total(), Duration::from_millis(503));
    }

    #[test]
    fn the_head_is_the_run_line_then_one_row_per_phase_absent_as_a_dash() {
        let report = metrics().render();
        let lines: Vec<&str> = report.lines().collect();
        assert_eq!(
            lines[0],
            "run: 503.0 ms total, 3 replica operations, 2.0 MiB of file content moved"
        );
        assert_eq!(lines[1], "cpu: —");
        assert_eq!(lines[3], "phases");
        assert_eq!(lines[4], "  connect         3.0 ms");
        assert_eq!(lines[5], "  lock                 —");
        assert_eq!(lines[8], "  present         30.0 s");
    }

    #[test]
    fn operations_print_count_total_mean_and_max_per_replica() {
        let report = metrics().render();
        assert!(report.contains("replica a — 2 operations, 0 B of file content"));
        assert!(
            report.contains("  write                      2    6.0 ms    3.0 ms    4.0 ms"),
            "{report}"
        );
        assert!(report.contains("  read                       1    300 µs    300 µs    300 µs"));
    }

    #[test]
    fn take_landed_is_listed_as_a_wait_after_the_work_however_long() {
        let mut metrics = metrics();
        metrics
            .b
            .record(ReplicaOp::TakeLanded, Duration::from_secs(9));
        metrics.b.record(ReplicaOp::Stage, Duration::from_millis(7));
        let report = metrics.render();
        let b = &report[report.find("replica b").unwrap()..];
        let row = |name: &str| b.find(&format!("\n  {name} ")).expect(name);
        let waits = b.find("\n  waits, not busy time\n").expect("waits");
        assert!(row("stage") < row("read"), "{b}");
        assert!(row("read") < waits, "{b}");
        assert!(waits < row("takeLanded"), "{b}");
        let a = &report[report.find("replica a").unwrap()..report.find("replica b").unwrap()];
        assert!(!a.contains("waits"), "{a}");
    }

    #[test]
    fn the_received_mark_is_its_own_line_and_only_when_something_staged() {
        let mut metrics = metrics();
        assert!(!metrics.render().contains("received"));
        metrics.received = Some(Duration::from_millis(420));
        let report = metrics.render();
        let lines: Vec<&str> = report.lines().collect();
        assert_eq!(lines[1], "cpu: —");
        assert_eq!(lines[2], "received: 420.0 ms into apply");
        assert_eq!(lines[4], "phases");
    }

    #[test]
    fn cpu_is_reported_per_mib_moved() {
        let mut metrics = metrics();
        metrics.cpu = Some(Duration::from_millis(40));
        assert_eq!(metrics.cpu_per_mib(), Some(Duration::from_millis(20)));
        assert!(metrics.render().contains("cpu: 40.0 ms, 20.0 ms per MiB"));
        metrics.transferred_bytes = 0;
        assert!(metrics.render().contains("cpu: 40.0 ms\n"));
    }

    #[test]
    fn write_stages_print_for_a_replica_that_reported_some_and_not_otherwise() {
        let mut metrics = metrics();
        let mut stats = WriteStats::one_writer();
        stats.files = 1;
        stats.record(Stage::Write, Duration::from_millis(2));
        metrics.b.write_stats = Some(stats);
        metrics.a.write_stats = Some(WriteStats::one_writer());
        let report = metrics.render();
        assert_eq!(
            report.matches("  write stages (count").count(),
            1,
            "{report}"
        );
        let b = &report[report.find("replica b").unwrap()..];
        assert!(b.contains("  write stages (count, mean ms, total s):  write 1 2.000 0.002"));
        assert!(b.contains("  write writers 1  busy"));
    }
}
