import 'package:flutter/foundation.dart';

import 'package:dsync/dsync_core/models/read_probe_report.dart';
import 'package:dsync/dsync_core/models/scan_probe_report.dart';

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

/// The walk finished; [report] is what it found.
final class ScanCostMeasured extends ScanCostOutcome {
  const ScanCostMeasured(this.report);

  final ScanProbeReport report;
}

/// The walk could not run — the folder is gone, or this head has no grant to
/// read it. [message] is the whole line to show.
final class ScanCostFailed extends ScanCostOutcome {
  const ScanCostFailed(this.message);

  final String message;
}

/// Where the read-rate sweep stands (task 8347dd).
sealed class ReadRateOutcome {
  const ReadRateOutcome();
}

/// Nothing measured yet.
final class ReadRateIdle extends ReadRateOutcome {
  const ReadRateIdle();
}

/// The sweep is running, [done] of [total] samples in.
///
/// It carries its progress because it has progress to carry and the sweep
/// runs for minutes: a bare spinner over a `modes × depths` sweep says
/// nothing about whether it is a third of the way through or stuck, and the
/// probe reports each sample as it lands precisely so this can.
final class ReadRateMeasuring extends ReadRateOutcome {
  const ReadRateMeasuring({required this.done, required this.total});

  final int done;
  final int total;

  /// `null` until the first sample lands, which is what a determinate
  /// progress indicator wants for "running, nothing to show yet".
  double? get fraction => total == 0 || done == 0 ? null : done / total;
}

/// The sweep finished; [report] is the curve it measured.
final class ReadRateMeasured extends ReadRateOutcome {
  const ReadRateMeasured(this.report);

  final ReadProbeReport report;
}

/// The sweep could not run. [message] is the whole line to show.
final class ReadRateFailed extends ReadRateOutcome {
  const ReadRateFailed(this.message);

  final String message;
}

/// What the Diagnostics page renders: one outcome per probe, and nothing
/// else. Per the view-state role in `app_scope.dart` — the controller
/// decides, this holds what was decided.
///
/// The two probes are independent: each has its own outcome, either can run
/// while the other's report is on screen, and neither invalidates the other.
/// Both are about the one root the page was opened over, which is fixed for
/// the page's life, so there is no selection here for a report to fall out
/// of step with.
class DiagnosticsViewState extends ChangeNotifier {
  ScanCostOutcome _scanCost = const ScanCostIdle();
  ReadRateOutcome _readRate = const ReadRateIdle();

  ScanCostOutcome get scanCost => _scanCost;
  ReadRateOutcome get readRate => _readRate;

  /// Moves the scan-cost outcome. `DiagnosticsController` only.
  void recordScanCost(ScanCostOutcome outcome) {
    _scanCost = outcome;
    notifyListeners();
  }

  /// Moves the read-rate outcome. `DiagnosticsController` only.
  void recordReadRate(ReadRateOutcome outcome) {
    _readRate = outcome;
    notifyListeners();
  }
}
