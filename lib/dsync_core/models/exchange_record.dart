import 'package:dsync/dsync_core/models/far_side_report.dart';
import 'package:dsync/dsync_core/models/run_metrics.dart';

/// One remote exchange, split where it actually happened (SPEC §17).
///
/// **Why a record per call rather than counters per operation.** The split
/// used to be arithmetic over totals: `wire = total − queueWait` and
/// `link = meanWire − meanFar`, each summed by a different collaborator at a
/// different instant, and the second divided by a different denominator than
/// the first. Both were clamped at zero so a disagreement showed as a plausible
/// number rather than as a disagreement. Every figure here is instead read off
/// the instants of *one* call by the one object that sees all of them, and the
/// recorder only ever adds up quantities that are already split — which is the
/// difference between measuring a thing and reconstructing it.
///
/// `RemoteAgent` is that object: it is the only place that sees an operation
/// issued, admitted by the window, and finished, and that decodes what the
/// peer said about the same call on the way past.
class ExchangeRecord {
  final AgentOp op;

  /// Issued to admitted by `RequestWindow` — the operation's own path
  /// predecessor, the window's bound, or a barrier ahead of it. Not the link.
  final Duration queueWait;

  /// Admitted to finished: the request out, whatever the peer did, and the
  /// reply back. For `readFile` this is the whole stream, since that is what
  /// holds the slot.
  final Duration wire;

  /// What the peer said this same call cost it, or null when it said nothing
  /// — an older build, or one of the two replies with no field to carry it
  /// (SPEC §15.3). Absent, never zero.
  final FarSideReport? far;

  /// The reply's bytes arriving at `Channel.input` to this call's future
  /// completing — what *this* side spent on a reply it already had (SPEC
  /// §17).
  ///
  /// **The one figure on this path that is not an identity.** Per-action
  /// `wire` is concurrency over throughput by construction, so any split of
  /// it into a link term and a peer term is arguable; this is a span between
  /// two events on one clock, entirely inside this process, and it covers
  /// precisely what neither `far` nor a link latency can contain: decoding
  /// the frame, the route's delivery, the microtask hops, the window slot
  /// being released — plus any wait behind a paused subscription, since the
  /// stamp is taken when the reader was finally given the chunk. All of it
  /// serialises on one isolate's event loop, which is the constraint a
  /// concurrency figure hides.
  ///
  /// Null when the reply was not stamped: a `readFile`, whose frames are
  /// consumed at the caller's pace and would put the other replica's
  /// `writeFile` inside this span, and any reply that never arrived at all.
  final Duration? settle;

  const ExchangeRecord({
    required this.op,
    required this.queueWait,
    required this.wire,
    this.far,
    this.settle,
  });

  /// [wire] with the peer's own span taken out: what this one exchange cost
  /// the link, request out and reply back. Null when the peer did not report.
  ///
  /// A subtraction, but of two spans of *one* call that genuinely nest — the
  /// peer's span begins after the request lands and ends before the reply
  /// leaves — rather than of two aggregates sampled over different
  /// populations. It still carries what [FarSideReport.sendWait] exists to
  /// expose: the peer's reply waits on the peer's own sink after its span has
  /// stopped, and that wait is in here.
  Duration? get link {
    final span = far?.span;
    if (span == null) return null;
    return wire > span ? wire - span : Duration.zero;
  }
}
