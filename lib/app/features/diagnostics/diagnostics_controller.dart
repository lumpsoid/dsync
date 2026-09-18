import 'dart:io';

import 'package:dsync/dsync_core/models/read_probe_report.dart';
import 'package:dsync/dsync_core/models/rule_set.dart';
import 'package:dsync/dsync_core/probe/read_probe.dart';
import 'package:dsync/dsync_core/scan/case_folding.dart';
import 'package:dsync/dsync_core/scan/scan_probe.dart';
import 'package:dsync/dsync_core/scan/scanner.dart';

import 'diagnostics_view_state.dart';

/// Input methods of the Diagnostics page: run a probe over the replica root
/// this device holds, and record what it found.
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
/// §4.3), reads an archive from disk (§8.3) or writes anything. Both probes
/// open files that are already there and count; a folder mid-edit is a fine
/// thing to point them at.
///
/// The root is a parameter of each method rather than a field, so one cached
/// controller serves whichever replica the page was opened over, per the
/// controller role in `app_scope.dart`.
class DiagnosticsController {
  final DiagnosticsViewState state = DiagnosticsViewState();

  /// Hashing concurrency, taken from [Scanner]'s own default so the scanner
  /// rungs of the scan probe measure the scanner a run on this head actually
  /// uses rather than a differently-configured lookalike.
  final int _jobs = Scanner().jobs;

  /// Splits what a scan of [rootPath] costs into the platform's floor and
  /// this project's own code (task 1a341e).
  ///
  /// Minutes, on the tree sizes this exists for. The outcome is a state the
  /// page renders rather than a dialog, so the page stays usable while the
  /// walk runs.
  Future<void> measureScanCost(String rootPath, {int passes = 2}) async {
    state.recordScanCost(const ScanCostMeasuring());
    try {
      final report =
          await ScanProbe(
            jobs: _jobs,
            // Configured exactly as `ReplicaConnector` configures the scanner
            // a real run uses (SPEC §16), so the rungs that measure
            // `Scanner.scan` measure the scanner this head actually runs.
            foldKey: caseFoldKeyFor(detectsCaseFolding(rootPath)),
          ).run(
            rootPath: rootPath,
            // The app head carries no SPEC §9 rules — nothing here collects
            // them and `RunRequest` has no field for them — so an empty set
            // is what a run from this head actually scans with.
            rules: RuleSet(),
            passes: passes,
          );
      state.recordScanCost(ScanCostMeasured(report));
    } on FileSystemException catch (e) {
      state.recordScanCost(ScanCostFailed(_unreadable(rootPath, e)));
    }
  }

  /// Sweeps what reading [rootPath]'s files costs, across read modes and
  /// concurrency depths (task 8347dd).
  ///
  /// The sweep's shape is [ReadProbe]'s default and is not offered as a
  /// choice on screen: the depths and modes are what make the samples
  /// comparable against each other and against the figures already recorded
  /// in SPEC §5.3 and §17, and a report swept over some other set would not
  /// be readable beside them.
  Future<void> measureReadRate(String rootPath) async {
    const probe = ReadProbe();
    final total = ReadProbeMode.values.length * ReadProbe.defaultDepths.length;

    state.recordReadRate(ReadRateMeasuring(done: 0, total: total));
    try {
      var done = 0;
      final report = await probe.run(
        rootPath: rootPath,
        onSample: (_) {
          done++;
          state.recordReadRate(ReadRateMeasuring(done: done, total: total));
        },
      );
      state.recordReadRate(ReadRateMeasured(report));
    } on FileSystemException catch (e) {
      state.recordReadRate(ReadRateFailed(_unreadable(rootPath, e)));
    }
  }

  /// The one line to show when a probe could not read the root — the same
  /// failure for both, so the same sentence, including the hint that is
  /// nearly always the cause on Android.
  String _unreadable(String rootPath, FileSystemException e) =>
      'Could not read $rootPath: ${e.osError?.message ?? e.message}. '
      'Grant dsync access to all files, or pick a folder in the app\'s own '
      'documents instead.';
}
