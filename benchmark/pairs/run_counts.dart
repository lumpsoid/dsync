/// The action counts of one `dsync sync` run, read back from the SPEC §11.4
/// `summary:` line the CLI prints on stdout (task 84fc92).
///
/// A run is only a timing when every action it planned was applied: one whose
/// writes all failed (a phone without its All-files grant fails 3,000 writes
/// in a few seconds) is a fast run of nothing, and one that applied twice the
/// session's count (leftovers of an earlier session) timed a different tree.
class RunCounts {
  const RunCounts({required this.applied, required this.failed});

  final int applied;
  final int failed;

  /// Returns null when [output] holds no `summary:` line — a run that ended
  /// before printing one.
  static RunCounts? parse(String output) {
    final match = _summary.firstMatch(output);
    if (match == null) return null;
    return RunCounts(
      applied: int.parse(match.group(1)!),
      failed: int.parse(match.group(2)!),
    );
  }
}

final _summary = RegExp(
  r'^summary: applied=(\d+) .*\bfailed=(\d+)\b',
  multiLine: true,
);
