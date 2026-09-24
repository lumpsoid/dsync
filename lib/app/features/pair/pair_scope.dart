import '../../app_scope.dart';
import 'pair_controller.dart';

/// The cell for [PairController]; see the scope contract in
/// `app_scope.dart`.
final class PairScope extends Scope<PairController> {
  PairScope() : super(() => PairController(appScope.controller));
}

/// The single Pair scope.
final pairScope = PairScope();
