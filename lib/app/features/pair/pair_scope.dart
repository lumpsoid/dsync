import 'package:dsync/dsync_core/identity/enrolment_client.dart';

import '../../app_scope.dart';
import 'pair_controller.dart';

/// The cell for [PairController]; see the scope contract in `app_scope.dart`.
/// Names the real `enrolWithPeer` — the one place a socket-opening exchange
/// is wired into this feature.
final class PairScope extends Scope<PairController> {
  PairScope()
    : super(() => PairController(appScope.controller, enrol: enrolWithPeer));
}

/// The single Pair scope.
final pairScope = PairScope();
