import 'run_summary_info.dart';

/// How a run was stopped.
enum StopKind { gracefully, dropped }

/// How a run's session ended.
sealed class RunEnd {
  const RunEnd();
}

/// The run ran, to its end or until stopped; [timings] is the `--timings`
/// report.
final class RunRan extends RunEnd {
  const RunRan({
    required this.summary,
    required this.errored,
    required this.stopped,
    required this.timings,
  });

  final RunSummaryInfo? summary;
  final bool errored;
  final StopKind? stopped;
  final String timings;
}

/// A side could not be connected; nothing ran.
final class RunNotConnected extends RunEnd {
  const RunNotConnected(this.message);

  final String message;
}

/// Stopped while connecting; nothing ran.
final class RunStoppedConnecting extends RunEnd {
  const RunStoppedConnecting();
}
