import 'package:dsync/dsync_core/agent/request_window.dart';
import 'package:dsync/dsync_core/run/run_metrics_recorder.dart';

/// A [RequestWindow] that reports every admission delay to [metrics] against
/// the replica named [side] (SPEC §17) — what a head builds for a
/// `RemoteAgent` it wants measured.
///
/// **A function here rather than a constructor on either side**, because
/// neither should own the other: [RequestWindow] is pure scheduling and would
/// stop being testable without a recorder if it took one, while
/// [RunMetricsRecorder] is a ledger and has no business building a scheduler.
/// This is the one line that joins them, written once so the four places that
/// connect a remote replica cannot write it four slightly different ways.
RequestWindow meteredRequestWindow({
  required String side,
  required RunMetricsRecorder metrics,
}) =>
    RequestWindow(onWait: (op, wait) => metrics.countQueueWait(side, op, wait));
