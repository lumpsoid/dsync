import '../../app_scope.dart';
import '../../screen_wake.dart';
import 'run_controller.dart';

/// The cell for [SyncRunController]; see the scope contract in
/// `app_scope.dart`. The Run page takes `runScope.create()`, not
/// `controller`, and disposes what it got — the contract says why, and
/// `SyncRunController`'s doc comment says what dispose closes.
///
/// The default factory names the real [PlatformScreenWake] and
/// [storedKeepScreenAwake]; a test that
/// wants a real controller over a fake core and a fake wakelock uses
/// `setFactory`.
final class SyncRunScope extends Scope<SyncRunController> {
  SyncRunScope()
    : super(
        () => SyncRunController(
          appScope.controller,
          screenWake: const PlatformScreenWake(),
          keepScreenAwake: storedKeepScreenAwake,
        ),
      );
}

/// The stored keep-awake switch, freshly read — per run and per serve, so
/// a change on the Settings page applies from the next one. Throws
/// `AppSettingsStoreException` when the settings file cannot be read; the
/// controllers hold the screen then.
Future<bool> storedKeepScreenAwake() async =>
    (await (await appScope.controller.settings).load()).keepScreenAwake;

/// The single Run scope.
final runScope = SyncRunScope();
