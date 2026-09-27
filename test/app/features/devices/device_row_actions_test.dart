import 'package:dsync/app/features/devices/device_row_actions.dart';
import 'package:dsync/app/paired_device_row.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/row_actions.dart';

/// [deviceRowActions] over a plain row: the run button and the address,
/// and nothing destructive.
void main() {
  test('a device row sets up a run and copies its address', () {
    var runs = 0;
    final actions = deviceRowActions(
      PairedDeviceRow(
        name: 'desktop',
        deviceId: 'a1b2:c3d4',
        address: '10.0.0.7:28771',
        pairedAt: DateTime(2026, 9, 15),
        agreedRoots: const [],
        certificateIssuedAt: DateTime(2026, 1, 1),
        certificateExpiresAt: DateTime(2027, 1, 1),
        certificateWarning: null,
        verifiedAt: null,
      ),
      onRunSetup: () => runs++,
    );

    expect(describeActions(actions), [
      'Set up run',
      'Copy address = 10.0.0.7:28771',
    ]);
    choose(actions, 'Set up run');
    expect(runs, 1);
  });
}
