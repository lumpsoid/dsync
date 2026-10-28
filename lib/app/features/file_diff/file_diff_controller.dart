import 'dart:async';

import '../../app_controller.dart';
import '../../core_link/models/core_failure.dart';
import 'file_diff_view_state.dart';

/// Input methods of the diff page: reading one review row's two files and
/// showing how they differ. The page reads only; choosing a side stays on
/// the run review.
///
/// **One load, and a read nobody waits for is stopped.** Reading a remote
/// file is a transfer, so a page that leaves mid-read tells the core to
/// stop ([dispose]) rather than letting it run to an answer no one reads.
/// A result that lands after a newer [open] is dropped by generation, as
/// the Filters page drops a stale listing.
class FileDiffController {
  FileDiffController(this.app);

  final AppController app;

  /// The view state this controller renders into; owned here, disposed
  /// here.
  final FileDiffViewState state = FileDiffViewState();

  /// Bumped by every [open], so a comparison that lands after a newer one
  /// started is dropped instead of overwriting it.
  int _generation = 0;

  /// Set by [dispose]: a comparison landing after the page is gone writes
  /// nothing.
  bool _disposed = false;

  /// The compare the core is still answering, to cancel if the page goes
  /// first; null once it has answered.
  ({int session, int id})? _unfinished;

  /// Reads the row [args] names, showing what the row already knows until
  /// the comparison lands.
  Future<void> open(FileDiffArgs args) async {
    if (_disposed) return;
    final generation = ++_generation;
    _cancelUnfinished();
    state.recordReading(args);
    final compare = app.core.compareRow(args.session, args.row);
    final asked = (session: args.session, id: compare.id);
    _unfinished = asked;
    try {
      final comparison = await compare.reply;
      if (_current(generation)) state.recordComparison(comparison);
    } on CoreFailure catch (e) {
      if (_current(generation)) state.recordFailure(e.message);
    } finally {
      if (_unfinished == asked) _unfinished = null;
    }
  }

  /// Leaves the page: an unfinished read is cancelled. Safe to call twice.
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _cancelUnfinished();
    state.dispose();
  }

  bool _current(int generation) => !_disposed && generation == _generation;

  void _cancelUnfinished() {
    final unfinished = _unfinished;
    if (unfinished == null) return;
    _unfinished = null;
    unawaited(_cancel(unfinished.session, unfinished.id));
  }

  /// Cancels compare [id]. Refused when the review has closed meanwhile —
  /// and then there is no read left to stop.
  Future<void> _cancel(int session, int id) async {
    try {
      await app.core.cancelCompare(session, id);
    } on CoreFailure {
      // Nothing to stop: the review the read belonged to is gone.
    }
  }
}
