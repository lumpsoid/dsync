import 'package:dsync/app/run_keep_alive.dart';

/// A [RunKeepAlive] a test drives: it records whether it holds the run,
/// answers [hold] with [grants], and lets a test take the hold back as the
/// platform would ([expire]).
///
/// It refuses by default, the same as every platform but Android, so a
/// test that does not care sees backgrounding pause the run as it always
/// did.
class FakeRunKeepAlive implements RunKeepAlive {
  FakeRunKeepAlive({this.grants = false});

  /// What [hold] answers.
  bool grants;

  /// Whether the run is held right now.
  bool held = false;

  void Function()? _onExpired;

  /// The platform takes the hold back.
  void expire() {
    held = false;
    final expired = _onExpired;
    _onExpired = null;
    expired?.call();
  }

  @override
  Future<bool> hold({required void Function() onExpired}) async {
    held = true;
    _onExpired = onExpired;
    return grants;
  }

  @override
  Future<void> release() async {
    held = false;
    _onExpired = null;
  }
}
