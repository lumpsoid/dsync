import 'dart:io';

import 'package:flutter/services.dart';

/// Whether a live run is kept going while the app is in the background
/// (SPEC §11.4).
///
/// An interface because the real one is a platform channel no test can run,
/// and because two real ones ship: Android's foreground service, and the
/// no-op every other platform gets (the abstraction-at-the-border rule in
/// `CLAUDE.md`).
///
/// **This is not `ScreenWake`.** That one holds the *screen* on, and the
/// Settings page can turn it off; this one keeps the *run* alive with the
/// screen off or the app backgrounded, and is held for every live run
/// except while it waits on the user (the review, a guard's question). A
/// run it holds does not need the lifecycle pause in `SyncRunController`;
/// one it does not hold falls back to that pause.
abstract interface class RunKeepAlive {
  /// Keeps the run alive until [release]. Returns whether it now does: a
  /// platform that refused (Android's background-start restriction, say)
  /// answers `false`, and the run must pause on backgrounding as before.
  ///
  /// [onExpired] is called if the platform later takes the hold back by
  /// itself (Android 15's six-hour `dataSync` cap) — the run is no longer
  /// kept alive and must pause. Safe to call when already held.
  Future<bool> hold({required void Function() onExpired});

  /// Lets the run go. Safe to call when not held.
  Future<void> release();
}

/// The [RunKeepAlive] for the platform this head runs on. One for the
/// process, because the service and its channel are one.
final RunKeepAlive platformRunKeepAlive = Platform.isAndroid
    ? AndroidRunKeepAlive()
    : const NoRunKeepAlive();

/// Every platform but Android: nothing keeps a backgrounded run alive, so
/// the lifecycle pause stays the answer.
final class NoRunKeepAlive implements RunKeepAlive {
  const NoRunKeepAlive();

  @override
  Future<bool> hold({required void Function() onExpired}) async => false;

  @override
  Future<void> release() async {}
}

/// [RunKeepAlive] over Android's `SyncService` — a `dataSync` foreground
/// service holding a partial wake lock and a Wi-Fi lock (`MainActivity.kt`).
///
/// **Neither call ever throws**, for the reason `PlatformScreenWake` gives:
/// a hold that fails is a run that pauses on backgrounding, which is where
/// this head was before the service existed.
final class AndroidRunKeepAlive implements RunKeepAlive {
  AndroidRunKeepAlive() {
    _channel.setMethodCallHandler((call) async {
      if (call.method != 'expired') return;
      final expired = _onExpired;
      _onExpired = null;
      expired?.call();
    });
  }

  static const _channel = MethodChannel('dsync/run_keep_alive');

  void Function()? _onExpired;

  @override
  Future<bool> hold({required void Function() onExpired}) async {
    _onExpired = onExpired;
    try {
      await _channel.invokeMethod<void>('start');
      return true;
    } on MissingPluginException {
      _onExpired = null;
      return false;
    } on PlatformException {
      _onExpired = null;
      return false;
    }
  }

  @override
  Future<void> release() async {
    _onExpired = null;
    try {
      await _channel.invokeMethod<void>('stop');
    } on MissingPluginException {
      // Nothing was held.
    } on PlatformException {
      // The service is gone already, or never came up.
    }
  }
}
