import '../../app_scope.dart';
import '../pair_show/pair_show_scope.dart';
import 'pair_controller.dart';

/// The cell for [PairController]; see the scope contract in
/// `app_scope.dart`. The port sent with a redeemed code is
/// [storedPeerPort], the one this device's Serve page binds.
final class PairScope extends Scope<PairController> {
  PairScope()
    : super(
        () => PairController(appScope.controller, peerPort: storedPeerPort),
      );
}

/// The single Pair scope.
final pairScope = PairScope();
