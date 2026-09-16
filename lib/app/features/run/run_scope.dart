import '../../app_scope.dart';
import 'run_controller.dart';

/// The cell for [SyncRunController]; see the scope contract in
/// `app_scope.dart`.
final class SyncRunScope extends Scope<SyncRunController> {
  SyncRunScope() : super(() => SyncRunController(appScope.controller));
}

/// The single Run scope.
final runScope = SyncRunScope();
