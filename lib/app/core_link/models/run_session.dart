import 'run_view.dart';

/// A run session the core opened: its id, which every intent names, and
/// its [views] — the whole run after every change, the latest one what to
/// show.
final class RunSession {
  const RunSession({required this.session, required this.views});

  final int session;
  final Stream<RunView> views;
}
