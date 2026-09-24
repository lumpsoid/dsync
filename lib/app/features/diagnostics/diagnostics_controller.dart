import '../../app_controller.dart';
import '../../core_link/models/core_failure.dart';
import 'diagnostics_view_state.dart';

/// Input methods of the Diagnostics page: run the scan probe over the
/// replica root this device holds, and record what it found.
///
/// **Why measuring is in the app at all.** The device whose cost profile
/// exists nowhere else is this one: a phone differs from a desktop in CPU
/// *and* storage *and* OS at once, so no benchmark run on a laptop can say
/// whether a figure measured here is the platform's floor or this code's.
/// Every off-device way of running the same measurement — a `flutter drive`
/// harness in particular — reinstalls the app to do it, and reinstalling is
/// what drops the All-files grant (`FolderPicker.requestAccess`) that makes
/// a replica root readable at all. The measurement has to run inside the app
/// that already holds the grant.
///
/// **Measurement only.** Nothing here starts a run, takes a lock (SPEC
/// §4.3), reads an archive from disk (§8.3) or writes anything. The core's
/// probe lists files that are already there and counts, with the jobs and
/// case folding a real scan of the folder would use; a folder mid-edit is a
/// fine thing to point it at.
///
/// The root is a parameter rather than a field, so one cached controller
/// serves whichever replica the page was opened over, per the controller
/// role in `app_scope.dart`.
class DiagnosticsController {
  DiagnosticsController(this.app);

  final AppController app;

  final DiagnosticsViewState state = DiagnosticsViewState();

  /// Splits what a scan of [rootPath] costs into the platform's floor and
  /// this project's own code (task 1a341e), [passes] times over.
  ///
  /// Minutes, on the tree sizes this exists for. The outcome is a state the
  /// page renders rather than a dialog, so the page stays usable while the
  /// walk runs.
  Future<void> measureScanCost(String rootPath, {int passes = 2}) async {
    state.recordScanCost(const ScanCostMeasuring());
    try {
      final report = await app.core.probeScan(rootPath, passes: passes);
      state.recordScanCost(ScanCostMeasured(report));
    } on CoreFailure catch (e) {
      state.recordScanCost(
        ScanCostFailed(
          'Could not read $rootPath: ${e.message}. Grant dsync access to all '
          'files, or pick a folder in the app\'s own documents instead.',
        ),
      );
    }
  }
}
