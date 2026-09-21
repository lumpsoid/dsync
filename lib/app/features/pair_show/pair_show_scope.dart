import 'dart:io';

import '../../app_scope.dart';
import 'pair_show_controller.dart';

/// The cell for [PairShowController]; see the scope contract in
/// `app_scope.dart`. The Show-this-device's-code page takes
/// `pairShowScope.create()`, not the cached `controller`, and disposes what
/// it got: the controller owns a bound socket, and a second page sharing one
/// would mean two windows over one endpoint.
///
/// The default factory names the real [bindEnrolmentListenerOnThisDevice] —
/// the one place a socket-binding endpoint is wired into this feature — and
/// the address it binds, which is this head's equivalent of `dsync pair show
/// --bind` (task 2b26ac).
///
/// `anyIPv4`: the same default the CLI's flag carries, so both heads listen
/// in the same place until somebody says otherwise. `::` would also accept
/// IPv4-mapped connections, but it fails outright on a host with IPv6
/// disabled and a silent fallback would make that undiagnosable, so IPv6 is
/// opt-in. The head has no settings surface to opt in through yet; when it
/// grows one, this line is what it writes to.
final class PairShowScope extends Scope<PairShowController> {
  PairShowScope()
    : super(
        () => PairShowController(
          appScope.controller,
          bind: bindEnrolmentListenerOnThisDevice,
          bindAddress: InternetAddress.anyIPv4,
        ),
      );
}

/// The single Show-this-device's-code scope.
final pairShowScope = PairShowScope();
