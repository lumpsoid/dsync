import 'package:dsync/app/core_link/fake_core_link.dart';
import 'package:dsync/app/core_link/models/core_failure.dart';
import 'package:dsync/app/core_link/models/scan_probe_layer.dart';
import 'package:dsync/app/core_link/models/scan_probe_result.dart';
import 'package:dsync/app/features/diagnostics/diagnostics_controller.dart';
import 'package:dsync/app/features/diagnostics/diagnostics_view_state.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fake_head.dart';

/// What the Diagnostics controller owes its page: an outcome a switch can be
/// exhaustive over, the core's report when it measured, and a readable line
/// when a root cannot be read. The probe's own correctness is the core's
/// (native/hub/tests/hub/commands.rs).
void main() {
  late FakeCoreLink core;
  late DiagnosticsController controller;

  setUp(() {
    core = FakeCoreLink();
    controller = DiagnosticsController(fakeApp(core));
  });

  const layer = ScanProbeLayer(
    label: 'list',
    elapsed: Duration(milliseconds: 12),
    files: 1,
    directories: 1,
    bytes: 1,
    microsPerFile: 12000,
  );

  test('measures the given root and records the core\'s report', () async {
    core.scanProbe = const ScanProbeResult(
      root: '/tmp/notes',
      report: 'scan probe: /tmp/notes',
      passes: [
        [layer],
      ],
    );
    final seen = <ScanCostOutcome>[];
    controller.state.addListener(() => seen.add(controller.state.scanCost));

    await controller.measureScanCost('/tmp/notes', passes: 1);

    expect(seen.first, isA<ScanCostMeasuring>());
    final outcome = controller.state.scanCost;
    expect(outcome, isA<ScanCostMeasured>());
    expect((outcome as ScanCostMeasured).report, same(core.scanProbe));
    expect(core.calls, ['probeScan']);
  });

  test(
    'a root the core cannot read fails with its reason and the way out',
    () async {
      core.failNext = const CoreFailure('No such file or directory');

      await controller.measureScanCost('/tmp/gone', passes: 1);

      expect(
        controller.state.scanCost,
        isA<ScanCostFailed>().having(
          (f) => f.message,
          'message',
          allOf(
            contains('Could not read /tmp/gone'),
            contains('No such file or directory'),
            contains('all files'),
          ),
        ),
      );
    },
  );
}
