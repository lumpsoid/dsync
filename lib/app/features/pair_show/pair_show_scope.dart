import '../../app_scope.dart';
import 'pair_show_controller.dart';

/// The cell for [PairShowController]; see the scope contract in
/// `app_scope.dart`. The Show-this-device's-code page takes
/// `pairShowScope.create()`, not the cached `controller`, and disposes what
/// it got: the controller owns a bound socket, and a second page sharing one
/// would mean two windows over one endpoint.
///
/// The default factory names the real [bindEnrolmentListenerOnThisDevice] —
/// the one place a socket-binding endpoint is wired into this feature.
final class PairShowScope extends Scope<PairShowController> {
  PairShowScope()
    : super(
        () => PairShowController(
          appScope.controller,
          bind: bindEnrolmentListenerOnThisDevice,
        ),
      );
}

/// The single Show-this-device's-code scope.
final pairShowScope = PairShowScope();
