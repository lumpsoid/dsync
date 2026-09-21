import 'package:flutter/services.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

/// Whether the screen is held awake while a run is live (SPEC §11.4).
///
/// An interface because the real one is a platform channel and no test can
/// run it (the abstraction-at-the-border rule in `CLAUDE.md`). One
/// interface for two calls, because they are one fact with two values:
/// something is either holding the screen on or it is not.
///
/// **This is the half of the screen-lock problem that prevention can
/// reach.** It stops the *idle timeout* from locking the phone in the
/// middle of an apply loop, which is the common case and the one the user
/// never asked for. It does nothing about a user who presses the power
/// button, or who switches to another app: that is the lifecycle pause in
/// `SyncRunController`, and the two together are SPEC §11.4's requirement.
abstract interface class ScreenWake {
  /// Holds the screen on. Safe to call when it is already held.
  Future<void> enable();

  /// Lets the screen time out again. Safe to call when it is not held.
  Future<void> disable();
}

/// [ScreenWake] over `wakelock_plus` — the one place this head touches the
/// plugin.
///
/// **Neither call ever throws.** A keep-awake that fails is a screen that
/// times out, which is exactly where this head was before the plugin
/// existed; failing the run over it would be the tail wagging the dog. The
/// platforms with no implementation are real — a `flutter test` binding
/// answers every channel with `MissingPluginException`, and so does a head
/// built for a platform the plugin does not cover — so the failure is
/// expected rather than exceptional, and is swallowed here rather than at
/// each of the call sites in `SyncRunController`.
final class PlatformScreenWake implements ScreenWake {
  const PlatformScreenWake();

  @override
  Future<void> enable() => _quietly(() => WakelockPlus.enable());

  @override
  Future<void> disable() => _quietly(() => WakelockPlus.disable());

  Future<void> _quietly(Future<void> Function() call) async {
    try {
      await call();
    } on MissingPluginException {
      // No native half on this platform: the screen times out as it always
      // did.
    } on PlatformException {
      // The native half refused. Same outcome, same reasoning.
    }
  }
}
