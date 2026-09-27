import '../../app_scope.dart';
import '../../mass_delete_guard.dart';
import '../../screen_wake.dart';
import '../../warn_size.dart';
import 'run_controller.dart';

/// The cell for [SyncRunController]; see the scope contract in
/// `app_scope.dart`. The Run page takes `runScope.create()`, not
/// `controller`, and disposes what it got — the contract says why, and
/// `SyncRunController`'s doc comment says what dispose closes.
///
/// The default factory names the real [PlatformScreenWake],
/// [storedKeepScreenAwake], [storedWarnSize] and [storedMassDeleteGuard];
/// a test that
/// wants a real controller over a fake core and a fake wakelock uses
/// `setFactory`.
final class SyncRunScope extends Scope<SyncRunController> {
  SyncRunScope()
    : super(
        () => SyncRunController(
          appScope.controller,
          screenWake: const PlatformScreenWake(),
          keepScreenAwake: storedKeepScreenAwake,
          defaultWarnSize: storedWarnSize,
          massDeleteGuard: storedMassDeleteGuard,
        ),
      );
}

/// The stored keep-awake switch, freshly read — per run and per serve, so
/// a change on the Settings page applies from the next one. Throws
/// `AppSettingsStoreException` when the settings file cannot be read; the
/// controllers hold the screen then.
Future<bool> storedKeepScreenAwake() async =>
    (await (await appScope.controller.settings).load()).keepScreenAwake;

/// The stored warn size, freshly read per run, as
/// [storedKeepScreenAwake]. Throws `AppSettingsStoreException` when the
/// settings file cannot be read; the controller warns about no size then.
Future<WarnSize> storedWarnSize() async =>
    (await (await appScope.controller.settings).load()).warnSize;

/// The stored delete-guard thresholds, freshly read per run, as
/// [storedKeepScreenAwake]. Throws `AppSettingsStoreException` when the
/// settings file cannot be read; the controller uses the defaults then.
Future<MassDeleteGuard> storedMassDeleteGuard() async =>
    (await (await appScope.controller.settings).load()).massDeleteGuard;

/// The single Run scope.
final runScope = SyncRunScope();
