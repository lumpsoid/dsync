import '../../app_controller.dart';
import 'pair_view_state.dart';

/// Input methods of the Pair page: enrolling against a `dsync-pair:v1:`
/// payload (SPEC §4.4).
///
/// Takes the [AppController] it borrows the application from as a
/// constructor argument, per the controller role in `app_scope.dart`. Its
/// inputs land with the page itself.
class PairController {
  PairController(this.app);

  final AppController app;

  /// The view state this controller renders into; owned here, disposed here.
  final PairViewState state = PairViewState();

  void dispose() => state.dispose();
}
