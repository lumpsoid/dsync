import '../../app_scope.dart';
import '../../screen_wake.dart';
import '../pair_show/pair_show_scope.dart';
import '../run/run_scope.dart';
import 'serve_controller.dart';

/// The cell for [ServeController]; see the scope contract in
/// `app_scope.dart`. The Serve page takes `serveScope.create()`, not the
/// cached `controller`, and disposes what it got: the controller owns a
/// serving session, and a second page sharing one would mean two views over
/// one listener, one of which can stop it under the other.
///
/// The default factory names the same [PlatformScreenWake] and
/// [storedKeepScreenAwake] the Run feature uses: one switch covers both.
///
/// The bind address and port are [storedBindAddress] and [storedPeerPort],
/// the Pair-show scope's own readers, rather than a second copy of the same
/// three lines: each is one setting, edited in one place, and the port a
/// pairing code names must be the one serve binds.
final class ServeScope extends Scope<ServeController> {
  ServeScope()
    : super(
        () => ServeController(
          appScope.controller,
          bindAddress: storedBindAddress,
          peerPort: storedPeerPort,
          screenWake: const PlatformScreenWake(),
          keepScreenAwake: storedKeepScreenAwake,
        ),
      );
}

/// The single Serve scope.
final serveScope = ServeScope();
