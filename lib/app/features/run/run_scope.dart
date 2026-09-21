import '../../app_scope.dart';
import 'replica_connector.dart';
import 'run_controller.dart';
import '../../screen_wake.dart';

/// The cell for [SyncRunController]; see the scope contract in
/// `app_scope.dart`. The Run page takes `runScope.create()`, not
/// `controller`, and disposes what it got — the contract says why, and
/// `SyncRunController`'s doc comment says what dispose closes.
///
/// The default factory names the production [dialPeer] and the real
/// [PlatformScreenWake]; a test that wants a real controller over a fake
/// dial and a fake wakelock uses `setFactory`.
final class SyncRunScope extends Scope<SyncRunController> {
  SyncRunScope()
    : super(
        () => SyncRunController(
          appScope.controller,
          dial: dialPeer,
          screenWake: const PlatformScreenWake(),
        ),
      );
}

/// The single Run scope.
final runScope = SyncRunScope();
