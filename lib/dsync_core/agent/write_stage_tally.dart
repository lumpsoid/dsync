import 'package:dsync/dsync_core/models/write_stage.dart';
import 'package:dsync/dsync_core/models/write_stage_stats.dart';

/// Accumulates one session's [WriteStageStats] as its served `writeFile`s
/// move through their stages (SPEC §17, task 9a89f7).
///
/// **Always on, so it is counters only.** Each event is a residence add and
/// two counter updates on instants the caller already read; nothing is kept
/// per write beyond the [WriteStageTrack] the write itself holds. Pure — the
/// instants are handed in — so the arithmetic is tested with plain values.
///
/// Connection-scoped, like the agent it measures: one session's writes, read
/// once on its `unlock` reply.
class WriteStageTally {
  int _files = 0;
  Duration? _first;
  Duration _last = Duration.zero;
  int _serving = 0;
  int _peakServing = 0;
  Duration _held = Duration.zero;
  final List<Duration> _residence = List.filled(
    WriteStage.values.length,
    Duration.zero,
  );
  final List<int> _live = List.filled(WriteStage.values.length, 0);
  final List<int> _peak = List.filled(WriteStage.values.length, 0);

  /// A write dispatched [at], whose request was decoded at [arrived] — or,
  /// from a router that stamps no arrivals, taken to be dispatched the moment
  /// it arrived.
  WriteStageTrack begin({required Duration? arrived, required Duration at}) {
    final decoded = arrived ?? at;
    final first = _first;
    if (first == null || decoded < first) _first = decoded;
    _residence[WriteStage.queued.index] += at - decoded;
    _serving++;
    if (_serving > _peakServing) _peakServing = _serving;
    _enter(WriteStage.awaiting);
    return WriteStageTrack._(this, at);
  }

  /// The figures so far, with the router's [inputBlocked] beside them — the
  /// one this tally cannot count, because it belongs to no write.
  WriteStageStats stats({Duration inputBlocked = Duration.zero}) =>
      WriteStageStats(
        files: _files,
        window: _first == null ? Duration.zero : _last - _first!,
        residence: {
          for (final stage in WriteStage.values) stage: _residence[stage.index],
        },
        peaks: {
          for (final stage in WriteStage.values)
            if (stage != WriteStage.queued) stage: _peak[stage.index],
        },
        peakServing: _peakServing,
        held: _held,
        inputBlocked: inputBlocked,
      );

  void _enter(WriteStage stage) {
    final live = ++_live[stage.index];
    if (live > _peak[stage.index]) _peak[stage.index] = live;
  }

  void _leave(WriteStage stage, Duration since, Duration at) {
    _live[stage.index]--;
    _residence[stage.index] += at - since;
  }

  void _end(WriteStage stage, Duration since, Duration at) {
    _leave(stage, since, at);
    _serving--;
    _files++;
    if (at > _last) _last = at;
  }
}

/// One write's position in its [WriteStageTally]: the stage it is in and
/// since when. Stages only move forward; a move to the stage already held is
/// ignored, so a caller can report "a frame was taken" without first asking
/// whether it was the first.
class WriteStageTrack {
  final WriteStageTally _tally;
  WriteStage _stage = WriteStage.awaiting;
  Duration _since;
  bool _ended = false;

  WriteStageTrack._(this._tally, this._since);

  /// Moves this write into [stage] at [at], if that is further on than where
  /// it is.
  void enter(WriteStage stage, Duration at) {
    if (_ended || stage.index <= _stage.index) return;
    _tally._leave(_stage, _since, at);
    _tally._enter(stage);
    _stage = stage;
    _since = at;
  }

  /// A `fileBytes` frame decoded at [arrived] and taken by the handler at
  /// [at].
  void took({required Duration? arrived, required Duration at}) {
    if (arrived != null && at > arrived) _tally._held += at - arrived;
  }

  /// The write is over — replied to, or failed — at [at]. Once only.
  void end(Duration at) {
    if (_ended) return;
    _ended = true;
    _tally._end(_stage, _since, at);
  }
}
