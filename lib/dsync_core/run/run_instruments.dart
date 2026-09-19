import 'package:dsync/dsync_core/agent/agent.dart';
import 'package:dsync/dsync_core/agent/metered_agent.dart';
import 'package:dsync/dsync_core/agent/remote_agent.dart';
import 'package:dsync/dsync_core/models/run_metrics.dart';
import 'package:dsync/dsync_core/protocol/channel.dart';
import 'package:dsync/dsync_core/protocol/metered_channel.dart';
import 'package:dsync/dsync_core/run/run_metrics_recorder.dart';

/// Everything a run is measured with, assembled in one place (SPEC §17).
///
/// **One object, because the wiring was the weak part.** The pieces —
/// `MeteredAgent`, `MeteredChannel`, and the sink `RemoteAgent` reports each
/// exchange to — are each individually right and were installed by hand at
/// seven call sites, none of which could tell whether it had installed all of
/// them. A connection wired with a metered channel and an unmetered agent
/// produces a report that looks complete and is not, and the failure is
/// silent: every figure it can still compute comes out plausible. This is the
/// one line each of those sites now writes.
///
/// **Concrete, no interface, one implementation** (CLAUDE.md: "abstraction
/// lives at the border"). It builds decorators over dependencies that are
/// already abstract; a second implementation would be a rename.
///
/// **It is the run's ledger and nothing else's.** One per run attempt, not
/// one per process and not one per controller: [RunMetrics.elapsed] runs from
/// construction, and phase totals, operation counts and byte counts all
/// *add*, so a second attempt through the same instance reports both attempts
/// as one run and says nothing about having done so. A head that can retry —
/// which the app's can — builds a fresh one for each attempt.
class RunInstruments {
  /// The ledger every instrument here writes into, and what a head hands to
  /// `RunController` for its phase spans.
  ///
  /// Exposed rather than wrapped: the recorder's phase API is already the
  /// right shape for its one caller, and a delegating copy of it here would
  /// be a second place for it to drift.
  final RunMetricsRecorder recorder;

  /// [elapsed] defaults to a [Stopwatch] started here, which is why a head
  /// constructs this at the top of a run attempt rather than earlier:
  /// [RunMetrics.elapsed] is measured from this moment.
  RunInstruments({Elapsed? elapsed})
    : recorder = RunMetricsRecorder(elapsed: elapsed);

  /// [inner] timed at the `Agent` boundary as the replica named [side].
  ///
  /// [remote] is passed rather than inferred because nothing visible from
  /// here distinguishes a `LocalAgent` from a `RemoteAgent` — that is the
  /// point of [Agent] (SPEC §4.1) — and the caller that built it knows.
  Agent agent(Agent inner, {required String side, required bool remote}) =>
      MeteredAgent(inner, side: side, metrics: recorder, remote: remote);

  /// [inner] counted as the transport reaching the replica named [side].
  ///
  /// Wrap the *outermost* channel a head builds — outside
  /// `IdleDeadlineChannel`, so its heartbeats count as the traffic they are,
  /// and outside any future compression, so the figure is bytes on the link
  /// rather than bytes before it.
  Channel channel(Channel inner, {required String side}) =>
      MeteredChannel(inner, side: side, metrics: recorder);

  /// Where a `RemoteAgent` for [side] reports each exchange's measured split.
  ///
  /// A function here rather than a constructor on either side: `RemoteAgent`
  /// speaks the protocol and would stop being constructible without a
  /// recorder if it took one, and the recorder is a ledger with no business
  /// knowing about connections. This is the one line that joins them.
  ExchangeSink exchanges(String side) =>
      (record) => recorder.recordExchange(side, record);

  /// Everything measured so far. Safe to take mid-run — see
  /// [RunMetricsRecorder.snapshot].
  RunMetrics snapshot() => recorder.snapshot();
}
