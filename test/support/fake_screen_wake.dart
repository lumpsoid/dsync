import 'package:dsync/app/screen_wake.dart';

/// A [ScreenWake] a test drives: it records what it was asked for, so a
/// test can assert that the screen is held for exactly as long as a run is
/// live.
///
/// The interface exists because the real one is a platform channel that no
/// test binding answers (see `screen_wake.dart`), so this is what stands in
/// for it everywhere a [SyncRunController] is built in a test.
class FakeScreenWake implements ScreenWake {
  /// Whether the screen is held right now — the fact the controller keeps
  /// in step with the run's phase.
  bool held = false;

  /// Every call, in order, as `true` for enable and `false` for disable.
  /// A test that cares about churn — the phase moves once per applied
  /// action — reads its length.
  final List<bool> calls = [];

  @override
  Future<void> enable() async {
    calls.add(true);
    held = true;
  }

  @override
  Future<void> disable() async {
    calls.add(false);
    held = false;
  }
}
