import '../../app_controller.dart';
import 'devices_view_state.dart';

/// Input methods of the Devices page: the paired device list, the home page.
///
/// Takes the [AppController] it borrows the application from as a
/// constructor argument, per the controller role in `app_scope.dart`. Its
/// inputs land with the page itself.
class DevicesController {
  DevicesController(this.app);

  final AppController app;

  /// The view state this controller renders into; owned here, disposed here.
  final DevicesViewState state = DevicesViewState();

  void dispose() => state.dispose();
}
