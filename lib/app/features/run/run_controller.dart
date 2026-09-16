import '../../app_controller.dart';
import 'run_view_state.dart';

/// Input methods of the Run page: driving a `dsync_core` run and rendering
/// its `RunEvent`s (SPEC §9).
///
/// Named `SyncRunController` rather than `RunController` because the page
/// that fills this in drives `dsync_core`'s `RunController` and must import
/// both without a prefix on every use; the file keeps the
/// `<feature>_controller.dart` name of the layout in `app_scope.dart`.
///
/// Takes the [AppController] it borrows the application from as a
/// constructor argument, per the controller role in `app_scope.dart`. Its
/// inputs land with the page itself. Unlike the other feature controllers,
/// this one is handed out by `runScope.create()` and disposed by the page —
/// see the scope contract for why.
class SyncRunController {
  SyncRunController(this.app);

  final AppController app;

  /// The view state this controller renders into; owned here, disposed here.
  final SyncRunViewState state = SyncRunViewState();

  void dispose() => state.dispose();
}
