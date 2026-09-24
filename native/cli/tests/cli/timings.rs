//! The `--timings` report's head, pinned: `benchmark/pairs/run_timings.dart`
//! parses the `run:` and `cpu:` lines and the phase table, and
//! `test/benchmark/run_timings_test.dart` parses this very text. A layout
//! change breaks this test first, not a phone session.

use std::time::Duration;

use dsync_domain::{RunMetrics, RunPhase};

use crate::support::Site;

/// The same text as `test/benchmark/run_timings_test.dart`'s `report`.
const REPORT: &str = "\
run: 56.2 s total, 0 replica operations, 100.0 MiB of file content moved
cpu: 3000.0 ms, 30.0 ms per MiB

phases
  connect        22.3 ms
  lock                 —
  scan         2140.0 ms
  reconcile       480 µs
  present              —
  apply           54.0 s
  compact              —
  unlock               —
  disconnect           —
";

#[test]
fn the_report_head_is_what_the_bench_parser_reads() {
    let mut metrics = RunMetrics {
        transferred_bytes: 100 * 1024 * 1024,
        cpu: Some(Duration::from_secs(3)),
        ..RunMetrics::default()
    };
    metrics.add_phase(RunPhase::Connect, Duration::from_micros(22_300));
    metrics.add_phase(RunPhase::Scan, Duration::from_millis(2_140));
    metrics.add_phase(RunPhase::Reconcile, Duration::from_micros(480));
    metrics.add_phase(RunPhase::Apply, Duration::from_millis(54_012));
    let report = metrics.render();
    assert!(report.starts_with(REPORT), "{report}");
}

#[test]
fn a_run_prints_its_report_on_stderr_after_the_summary() {
    let site = Site::new();
    let (a, b) = (site.root("a"), site.root("b"));
    site.write("a/f.txt", "f");
    let finished = site.run(&["sync", &a, &b, "--batch", "--timings"]);
    finished.exits(0);
    assert!(finished.stdout.contains("summary: "), "{finished:#?}");
    assert!(finished.stderr.starts_with("run: "), "{finished:#?}");
    assert!(finished.stderr.contains("\ncpu: "), "{finished:#?}");
    assert!(
        finished.stderr.contains("\nphases\n  connect"),
        "{finished:#?}"
    );
}
