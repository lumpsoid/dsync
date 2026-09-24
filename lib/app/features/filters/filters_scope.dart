import '../../app_scope.dart';
import 'filters_controller.dart';

/// The cell for [FiltersController]; see the scope contract in
/// `app_scope.dart`.
///
/// The controller takes no dependencies: the Filters page reads the
/// filesystem and edits a list of patterns, and the folder it works over
/// arrives as the page's argument rather than from the application.
final class FiltersScope extends Scope<FiltersController> {
  FiltersScope() : super(() => FiltersController(appScope.controller));
}

/// The single filters scope.
final filtersScope = FiltersScope();
