import 'package:dsync/app/app_bootstrap.dart';
import 'package:dsync/app/device_identity_row.dart';
import 'package:dsync/app/app_controller.dart';
import 'package:dsync/app/app_scope.dart';
import 'package:dsync/app/features/devices/devices_controller.dart';
import 'package:dsync/app/features/devices/devices_page.dart';
import 'package:dsync/app/features/devices/devices_scope.dart';
import 'package:dsync/app/format_path.dart';
import 'package:dsync/app/paired_device_row.dart';
import 'package:dsync/app/profile_row.dart';
import 'package:dsync/app/core_link/models/root_kind.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fake_hub.dart';
import '../../support/fake_head.dart';

/// Rendering tests for the Devices page, driven the way the scope contract
/// in `app_scope.dart` intends: the controllers are pinned with
/// `setController` and the page is pumped directly. The rows are written
/// into `AppState` by the test standing in for `AppController` — nothing
/// here touches a store, because the page renders values, not devices.
void main() {
  late AppController app;
  late DevicesController controller;
  final opened = <String>[];
  final devicesOpened = <String>[];
  var pairOpened = 0;
  var thisDeviceOpened = 0;
  var sharedFoldersOpened = 0;

  setUp(() {
    app = fakeApp(FakeHub());
    controller = DevicesController(app);
    appScope.setController(app);
    devicesScope.setController(controller);
    opened.clear();
    devicesOpened.clear();
    pairOpened = 0;
    thisDeviceOpened = 0;
    sharedFoldersOpened = 0;
  });

  // Scopes are process-global: reset both so a pin cannot leak into the
  // next test.
  tearDown(appScope.reset);
  tearDown(devicesScope.reset);
  tearDown(() => controller.dispose());

  PairedDeviceRow row(
    String name, {
    String? certificateWarning,
    List<String> agreedRoots = const ['/srv/notes'],
    DateTime? verifiedAt,
  }) => PairedDeviceRow(
    name: name,
    deviceId: 'a1b2:c3d4:$name',
    address: '10.0.0.7:28771',
    pairedAt: DateTime(2026, 9, 15, 11, 21),
    agreedRootLabels: {for (final root in agreedRoots) root: elidePath(root)},
    certificateIssuedAt: DateTime(2026, 1, 1),
    certificateExpiresAt: DateTime(2027, 1, 1),
    certificateWarning: certificateWarning,
    verifiedAt: verifiedAt,
  );

  ProfileRow profile(String id, {required String peerDeviceId}) => ProfileRow(
    name: 'run $id',
    peerDeviceId: peerDeviceId,
    peerName: 'phone',
    entries: [
      ProfileEntryRow(
        entryId: id,
        kind: RootKind.folder,
        localRootPath: '/on-device/notes',
        remoteRootPath: '~/notes',
        localRootLabel: PathLabel.of('/on-device/notes'),
        remoteRootLabel: PathLabel.of('~/notes'),
        localRootRefusal: null,
      ),
    ],
    breakage: null,
    lastRunUnfinished: false,
  );

  void ready({String? certificateWarning}) => app.state.recordBootstrap(
    AppBootstrapReady(
      DeviceIdentityRow(
        name: 'this device',
        deviceId: 'ffff:0000',
        issuedAt: DateTime(2026, 1, 1),
        expiresAt: DateTime(2027, 1, 1),
        certificateWarning: certificateWarning,
      ),
    ),
  );

  Future<void> pumpPage(WidgetTester tester) => tester.pumpWidget(
    MaterialApp(
      home: DevicesPage(
        onOpenDevice: devicesOpened.add,
        onOpenRunSetup: opened.add,
        onOpenPair: () => pairOpened++,
        onOpenThisDevice: () => thisDeviceOpened++,
        onOpenSharedFolders: () => sharedFoldersOpened++,
      ),
    ),
  );

  testWidgets('lists every row with its rendered fields', (tester) async {
    ready();
    app.state.recordDevices([
      row('phone'),
      row('laptop', agreedRoots: const []),
    ]);

    await pumpPage(tester);

    expect(find.text('phone'), findsOneWidget);
    expect(find.text('laptop'), findsOneWidget);
    expect(find.text('10.0.0.7:28771'), findsNWidgets(2));
    expect(find.text('No paired devices.'), findsNothing);
    // The row is name, address, the saved-run count, warnings and the run
    // action. The pairing date, the grouped id and a non-zero roots count
    // are on the device's own page, one tap away.
    expect(find.text('a1b2:c3d4:phone'), findsNothing);
    expect(find.text('paired 2026-09-15'), findsNothing);
    expect(find.text('1 folder shared'), findsNothing);
  });

  testWidgets('a row says how many saved runs name that device', (
    tester,
  ) async {
    ready();
    app.state.recordDevices([row('phone'), row('laptop')]);
    app.state.recordProfiles([
      profile('p1', peerDeviceId: 'a1b2:c3d4:phone'),
      profile('p2', peerDeviceId: 'a1b2:c3d4:phone'),
      profile('p3', peerDeviceId: 'a1b2:c3d4:laptop'),
    ]);

    await pumpPage(tester);

    // The saved runs live on the home list, keyed by device id; nothing
    // else on this page or the device's own page says a device is used.
    expect(find.text('2 saved runs'), findsOneWidget);
    expect(find.text('1 saved run'), findsOneWidget);
  });

  testWidgets('a device no saved run names carries no run line', (
    tester,
  ) async {
    ready();
    app.state.recordDevices([row('phone')]);
    app.state.recordProfiles(const []);

    await pumpPage(tester);

    // Zero says only what "Set up run" beside it already says.
    expect(find.textContaining('saved run'), findsNothing);
    expect(find.text('Set up run'), findsOneWidget);
  });

  testWidgets('the run count follows the home list', (tester) async {
    ready();
    app.state.recordDevices([row('phone')]);
    await pumpPage(tester);
    expect(find.textContaining('saved run'), findsNothing);

    app.state.recordProfiles([profile('p1', peerDeviceId: 'a1b2:c3d4:phone')]);
    await tester.pump();

    expect(find.text('1 saved run'), findsOneWidget);
  });

  testWidgets('warns on the row when a pairing shares no folders', (
    tester,
  ) async {
    ready();
    app.state.recordDevices([
      row('phone'),
      row('laptop', agreedRoots: const []),
    ]);

    await pumpPage(tester);

    // A pairing that grants nothing is why a run finds nothing, and the
    // list is the only place it would otherwise be invisible.
    expect(find.text('no folders shared'), findsOneWidget);
    final line = tester.widget<Text>(find.text('no folders shared')).style;
    final theme = Theme.of(tester.element(find.text('laptop')));
    expect(line?.color, theme.colorScheme.tertiary);
  });

  testWidgets('leads with the name and puts the address under it', (
    tester,
  ) async {
    ready();
    app.state.recordDevices([row('phone')]);

    await pumpPage(tester);

    final name = tester.getTopLeft(find.text('phone')).dy;
    final address = tester.getTopLeft(find.text('10.0.0.7:28771')).dy;
    expect(name, lessThan(address));
  });

  testWidgets('every row names what a tap does and opens Run setup', (
    tester,
  ) async {
    ready();
    app.state.recordDevices([row('phone'), row('laptop')]);

    await pumpPage(tester);
    expect(find.text('Set up run'), findsNWidgets(2));
    await tester.tap(find.text('Set up run').last);

    expect(opened, ['a1b2:c3d4:laptop']);
  });

  testWidgets('empty state points at Pair', (tester) async {
    ready();
    app.state.recordDevices([]);

    await pumpPage(tester);
    expect(find.text('No paired devices.'), findsOneWidget);
    await tester.tap(find.text('Pair a device'));

    expect(pairOpened, 1);
  });

  testWidgets('the app-bar action opens Pair with a non-empty list', (
    tester,
  ) async {
    ready();
    app.state.recordDevices([row('phone')]);

    await pumpPage(tester);
    expect(find.text('Pair a device'), findsNothing);
    await tester.tap(find.byKey(const Key('devices-open-pair')));

    expect(pairOpened, 1);
  });

  testWidgets("shows a row's certificate warning only on that row", (
    tester,
  ) async {
    ready();
    app.state.recordDevices([
      row(
        'phone',
        certificateWarning: 'certificate for phone expires in 3 days',
      ),
      row('laptop'),
    ]);

    await pumpPage(tester);

    expect(
      find.text('certificate for phone expires in 3 days'),
      findsOneWidget,
    );
    expect(find.textContaining('laptop expires'), findsNothing);
  });

  testWidgets('shows the own-certificate warning once, naming the remedy', (
    tester,
  ) async {
    ready(certificateWarning: 'certificate for this host expires in 10 days');
    app.state.recordDevices([row('phone'), row('laptop')]);

    await pumpPage(tester);

    expect(find.textContaining('this host expires in 10 days'), findsOneWidget);
    expect(find.textContaining('Renew it under This device.'), findsOneWidget);
  });

  testWidgets('shows no own-certificate warning when there is none', (
    tester,
  ) async {
    ready();
    app.state.recordDevices([row('phone')]);

    await pumpPage(tester);

    expect(find.textContaining('dsync pair renew'), findsNothing);
  });

  testWidgets('re-renders when the application state changes', (tester) async {
    ready();
    app.state.recordDevices([row('phone')]);
    await pumpPage(tester);
    expect(find.text('phone'), findsOneWidget);

    app.state.recordDevices([row('laptop')]);
    await tester.pump();

    expect(find.text('phone'), findsNothing);
    expect(find.text('laptop'), findsOneWidget);
  });

  testWidgets("tapping a row opens that device's page with its id", (
    tester,
  ) async {
    ready();
    app.state.recordDevices([row('phone'), row('laptop')]);
    await pumpPage(tester);

    await tester.tap(find.text('laptop'));

    expect(devicesOpened, ['a1b2:c3d4:laptop']);
    // Syncing is the separate, named action: a tap is about managing the
    // device, not running against it.
    expect(opened, isEmpty);
  });

  testWidgets('the app bar opens This device', (tester) async {
    ready();
    await pumpPage(tester);

    await tester.tap(find.byKey(const Key('devices-open-this-device')));

    expect(thisDeviceOpened, 1);
  });

  testWidgets('the app bar opens Shared folders', (tester) async {
    ready();
    await pumpPage(tester);

    // The list says which devices are paired; that page says what each of
    // them may actually reach here.
    await tester.tap(find.byKey(const Key('devices-open-shared-folders')));

    expect(sharedFoldersOpened, 1);
  });

  testWidgets('the row does not offer revoke', (tester) async {
    ready();
    app.state.recordDevices([row('phone')]);

    await pumpPage(tester);

    // Revoking is on the device's own page, behind a confirmation: it sat
    // one mis-tap from "Set up run" here.
    expect(find.byTooltip('Revoke'), findsNothing);
    expect(find.byIcon(Icons.delete_outline), findsNothing);
    expect(controller.state.error, isNull);
  });

  testWidgets('shows the view state error line', (tester) async {
    ready();
    app.state.recordDevices([row('phone')]);
    await pumpPage(tester);
    expect(find.text('No paired device with id x'), findsNothing);

    controller.state.recordError('No paired device with id x');
    await tester.pump();

    expect(find.text('No paired device with id x'), findsOneWidget);
  });

  testWidgets(
    'a confirmed device carries a mark; an unconfirmed one does not',
    (tester) async {
      ready();
      app.state.recordDevices([
        row('phone', verifiedAt: DateTime(2026, 9, 20)),
        row('laptop'),
      ]);

      await pumpPage(tester);

      expect(
        find.byKey(const Key('device-verified-a1b2:c3d4:phone')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('device-verified-a1b2:c3d4:laptop')),
        findsNothing,
      );
    },
  );
}
