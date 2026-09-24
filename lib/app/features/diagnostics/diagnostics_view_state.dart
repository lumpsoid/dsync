import 'package:flutter/foundation.dart';

import '../../core_link/models/scan_probe_result.dart';

/// Where the scan-cost measurement stands (task 1a341e).
///
/// Measuring starts no run and decides nothing about one — it is a
/// diagnostic over a folder that is already chosen — which is why it is its
/// own sum type rather than a case of anything the Run feature carries.
sealed class ScanCostOutcome {
  const ScanCostOutcome();
}

/// Nothing measured yet.
final class ScanCostIdle extends ScanCostOutcome {
  const ScanCostIdle();
}

/// `DiagnosticsController.measureScanCost` is walking the tree. Minutes, on
/// the tree sizes this exists for, which is why it is a state the page
/// renders rather than a dialog it puts up.
final class ScanCostMeasuring extends ScanCostOutcome {
  const ScanCostMeasuring();
}

/// The walk finished; [report] is what the core measured.
final class ScanCostMeasured extends ScanCostOutcome {
  const ScanCostMeasured(this.report);

  final ScanProbeResult report;
}

/// The walk could not run — the folder is gone, or this head has no grant to
/// read it. [message] is the whole line to show.
final class ScanCostFailed extends ScanCostOutcome {
  const ScanCostFailed(this.message);

  final String message;
}

/// What the Diagnostics page renders: the probe's outcome, and nothing
/// else. Per the view-state role in `app_scope.dart` — the controller
/// decides, this holds what was decided.
class DiagnosticsViewState extends ChangeNotifier {
  ScanCostOutcome _scanCost = const ScanCostIdle();

  ScanCostOutcome get scanCost => _scanCost;

  /// Moves the scan-cost outcome. `DiagnosticsController` only.
  void recordScanCost(ScanCostOutcome outcome) {
    _scanCost = outcome;
    notifyListeners();
  }
}
