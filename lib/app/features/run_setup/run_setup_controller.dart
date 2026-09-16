import '../../app_controller.dart';
import 'run_setup_view_state.dart';

/// Input methods of the RunSetup page: picking the two locations a run syncs.
///
/// Takes the [AppController] it borrows the application from as a
/// constructor argument, per the controller role in `app_scope.dart`. Its
/// inputs land with the page itself.
class RunSetupController {
  RunSetupController(this.app);

  final AppController app;

  /// The view state this controller renders into; owned here, disposed here.
  final RunSetupViewState state = RunSetupViewState();

  void dispose() => state.dispose();
}
