/// A finished run's counts (SPEC §11.4).
final class RunSummaryInfo {
  const RunSummaryInfo({
    required this.applied,
    required this.skipped,
    required this.conflicts,
    required this.failed,
    required this.unreadable,
  });

  final int applied;
  final int skipped;
  final int conflicts;
  final int failed;
  final int unreadable;
}
