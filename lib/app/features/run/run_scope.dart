import '../../app_scope.dart';
import '../../screen_wake.dart';
import 'run_controller.dart';

/// The cell for [SyncRunController]; see the scope contract in
/// `app_scope.dart`. The Run page takes `runScope.create()`, not
/// `controller`, and disposes what it got — the contract says why, and
/// `SyncRunController`'s doc comment says what dispose closes.
///
/// The default factory names the real [PlatformScreenWake]; a test that
/// wants a real controller over a fake core and a fake wakelock uses
/// `setFactory`.
final class SyncRunScope extends Scope<SyncRunController> {
  SyncRunScope()
    : super(
        () => SyncRunController(
          appScope.controller,
          screenWake: const PlatformScreenWake(),
        ),
      );
}

/// The single Run scope.
final runScope = SyncRunScope();
