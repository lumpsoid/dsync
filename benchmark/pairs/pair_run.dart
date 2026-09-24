import 'radio_snapshot.dart';
import 'run_timings.dart';

/// One measured run of an interleaved comparison: which arm, what the run
/// report said, and the radio either side of it (task 84fc92).
class PairRun {
  const PairRun({
    required this.arm,
    required this.timings,
    required this.applied,
    required this.radioStart,
    required this.radioEnd,
  });

  /// Index into the session's two arms.
  final int arm;

  final RunTimings timings;

  /// The actions the run applied. Every run of a session should apply the
  /// same number; one that did not timed a different tree.
  final int applied;

  /// Null when the snapshot could not be read — the phone was off the
  /// network or adb failed. Shown as such; a run without its radio is not
  /// silently treated as a clean one.
  final RadioSnapshot? radioStart;
  final RadioSnapshot? radioEnd;

  /// What moved in the association during this run; empty when nothing did,
  /// null when either end was not read.
  List<String>? get radioChanges => switch ((radioStart, radioEnd)) {
    (final start?, final end?) => start.associationChangesTo(end),
    _ => null,
  };
}
