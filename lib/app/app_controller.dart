import 'app_state.dart';

/// The head's bootstrap orchestrator: owns [AppState] and, once the later
/// phases land them, the identity store and paths every feature controller
/// borrows rather than opens for itself (SPEC §5, §13).
///
/// Its constructor is where those dependencies will be threaded in — a
/// controller in this head takes what it needs as constructor arguments so a
/// test can hand it fakes and a scope can build it with real ones. See the
/// conventions in `app_scope.dart`.
class AppController {
  AppController();

  /// The application state this controller renders into. Owned here, not by
  /// the scope, so the controller can dispose it along with itself.
  final AppState state = AppState();
}
