import '../../app_scope.dart';
import 'file_diff_controller.dart';

/// The cell for [FileDiffController]; see the scope contract in
/// `app_scope.dart`.
///
/// The page takes a fresh controller with `create()` and disposes it: two
/// diff pages over two rows must not share a view, and a read landing
/// after its page is gone must not write into a later page's.
final class FileDiffScope extends Scope<FileDiffController> {
  FileDiffScope() : super(() => FileDiffController(appScope.controller));
}

/// The single file diff scope.
final fileDiffScope = FileDiffScope();
