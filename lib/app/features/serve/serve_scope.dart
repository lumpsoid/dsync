import 'dart:io';

import 'package:dsync/dsync_core/agent/agent_listener.dart';

import '../../app_scope.dart';
import '../../screen_wake.dart';
import '../pair_show/pair_show_scope.dart';
import 'serve_controller.dart';

/// The cell for [ServeController]; see the scope contract in
/// `app_scope.dart`. The Serve page takes `serveScope.create()`, not the
/// cached `controller`, and disposes what it got: the controller owns a
/// bound socket, and a second page sharing one would mean two views over
/// one listener, one of which can close it under the other.
///
/// The default factory names the real [AgentListener.bindSecure] — the one
/// place the replica listener is wired into this head — the real process
/// environment an incoming root is expanded against, and the same
/// [PlatformScreenWake] the Run feature uses.
///
/// The bind address is [storedBindAddress], the Pair-show scope's own
/// reader, rather than a second copy of the same three lines: it is one
/// setting, edited in one place, and the two listeners this head binds must
/// not be able to disagree about it.
final class ServeScope extends Scope<ServeController> {
  ServeScope()
    : super(
        () => ServeController(
          appScope.controller,
          bind: AgentListener.bindSecure,
          bindAddress: storedBindAddress,
          environment: Platform.environment,
          screenWake: const PlatformScreenWake(),
        ),
      );
}

/// The single Serve scope.
final serveScope = ServeScope();
