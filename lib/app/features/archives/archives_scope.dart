import '../../app_scope.dart';
import 'archives_controller.dart';

/// The cell for [ArchivesController]; see the scope contract in
/// `app_scope.dart`.
final class ArchivesScope extends Scope<ArchivesController> {
  ArchivesScope() : super(() => ArchivesController(appScope.controller));
}

/// The single Archives scope.
final archivesScope = ArchivesScope();
