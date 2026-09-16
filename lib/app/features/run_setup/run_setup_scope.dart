import '../../app_scope.dart';
import 'run_setup_controller.dart';

/// The cell for [RunSetupController]; see the scope contract in
/// `app_scope.dart`.
final class RunSetupScope extends Scope<RunSetupController> {
  RunSetupScope() : super(() => RunSetupController(appScope.controller));
}

/// The single RunSetup scope.
final runSetupScope = RunSetupScope();
