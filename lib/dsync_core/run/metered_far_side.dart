import 'package:dsync/dsync_core/agent/remote_agent.dart';
import 'package:dsync/dsync_core/run/run_metrics_recorder.dart';

/// A [FarSideSink] that records the peer's own span for each exchange into
/// [metrics] against the replica named [side] (SPEC §17) — what a head
/// supplies to a `RemoteAgent` it wants measured.
///
/// **A function here rather than a constructor on either side**, for the
/// reason `meteredRequestWindow` gives: `RemoteAgent` speaks the protocol and
/// would stop being constructible without a recorder if it took one, and the
/// recorder is a ledger with no business knowing about connections. This is
/// the one line that joins them, written once so the four places that connect
/// a remote replica cannot write it four slightly different ways.
FarSideSink meteredFarSide({
  required String side,
  required RunMetricsRecorder metrics,
}) =>
    (op, span) => metrics.countFarSide(side, op, span);
