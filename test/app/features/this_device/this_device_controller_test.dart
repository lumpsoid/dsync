import 'package:dsync/app/app_bootstrap.dart';
import 'package:dsync/app/app_controller.dart';
import 'package:dsync/app/features/this_device/this_device_controller.dart';
import 'package:dsync/app/features/this_device/this_device_view_state.dart';
import 'package:dsync/app/rust/bindings/bindings.dart' as wire;
import 'package:dsync/app/core_link/models/device_identity_info.dart';
import 'package:test/test.dart';

import '../../support/fake_hub.dart';
import '../../support/fake_head.dart';

/// The This device controller over a real `AppController` and a
/// `FakeHub`: what it asks the core for, and what the page is left
/// showing. The certificate itself is the core's (native/hub tests).
void main() {
  late FakeHub core;
  late AppController app;
  late ThisDeviceController controller;

  setUp(() {
    core = FakeHub();
    app = fakeApp(core);
    controller = ThisDeviceController(app);
  });

  tearDown(() {
    controller.dispose();
    app.dispose();
  });

  test('identity is null before bootstrap and the row after', () async {
    expect(controller.identity, isNull);

    await app.bootstrap();

    expect(controller.identity, isNotNull);
    expect(controller.identity!.deviceId, fakeIdentity.deviceId);
    expect(controller.identity!.name, 'this-device');
  });

  test('loadStateDirPath renders the core\'s state dir', () async {
    core.reply<wire.CoreCommandInit>(
      initialised(stateDir: '/data/state', profilesDir: '/data/state/profiles'),
    );

    await controller.loadStateDirPath();

    expect(controller.state.stateDirPath, '/data/state');
  });

  test('renew asks the core to re-issue and keeps the device id', () async {
    await app.bootstrap();
    final before = controller.identity!;

    await controller.renew();

    expect(core.sent<wire.CoreCommandRenewIdentity>(), [
      const wire.CoreCommandRenewIdentity(commonName: null),
    ]);
    expect(controller.identity!.deviceId, before.deviceId);
    expect(controller.state.outcome, isA<IdentitySucceeded>());
    expect(
      (controller.state.outcome as IdentitySucceeded).message,
      contains('keeps its id'),
    );
  });

  test('rename re-issues under the trimmed name, in the gate', () async {
    await app.bootstrap();
    final before = controller.identity!;
    core.reply<wire.CoreCommandRenewIdentity>(
      identityReply(
        DeviceIdentityInfo(
          deviceId: fakeIdentity.deviceId,
          commonName: 'workshop',
          issuedAt: DateTime.utc(2026, 6),
          expiresAt: DateTime.utc(2036, 6),
          expiryNote: null,
        ),
      ),
    );

    await controller.rename('  workshop  ');

    expect(core.sent<wire.CoreCommandRenewIdentity>(), [
      const wire.CoreCommandRenewIdentity(commonName: 'workshop'),
    ]);
    expect(controller.identity!.name, 'workshop');
    expect(controller.identity!.deviceId, before.deviceId);
    expect(
      (controller.state.outcome as IdentitySucceeded).message,
      contains('workshop'),
    );
  });

  test('a blank name is refused without asking the core', () async {
    await app.bootstrap();

    await controller.rename('   ');

    expect(controller.state.outcome, isA<IdentityFailed>());
    expect(core.sent<wire.CoreCommandRenewIdentity>(), isEmpty);
    expect(controller.identity!.name, 'this-device');
  });

  test('a refused renewal is rendered, not thrown', () async {
    await app.bootstrap();
    core.reply<wire.CoreCommandRenewIdentity>(
      failed('identity.key is missing'),
    );

    await controller.renew();

    expect(controller.state.outcome, isA<IdentityFailed>());
    expect(
      (controller.state.outcome as IdentityFailed).message,
      contains('identity.key'),
    );
    // The gate is left alone: a head that has already bootstrapped stays up.
    expect(app.state.bootstrap, isA<AppBootstrapReady>());
  });
}
