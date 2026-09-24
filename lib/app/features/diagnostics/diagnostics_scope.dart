import '../../app_scope.dart';
import 'diagnostics_controller.dart';

/// The cell for [DiagnosticsController]; see the scope contract in
/// `app_scope.dart`.
final class DiagnosticsScope extends Scope<DiagnosticsController> {
  DiagnosticsScope() : super(() => DiagnosticsController(appScope.controller));
}

/// The single Diagnostics scope.
final diagnosticsScope = DiagnosticsScope();
