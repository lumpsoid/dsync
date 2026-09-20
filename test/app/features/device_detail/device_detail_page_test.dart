import 'dart:io';

import 'package:dsync/app/app_controller.dart';
import 'package:dsync/app/app_paths.dart';
import 'package:dsync/app/app_scope.dart';
import 'package:dsync/app/features/device_detail/device_detail_controller.dart';
import 'package:dsync/app/features/device_detail/device_detail_page.dart';
import 'package:dsync/app/features/device_detail/device_detail_scope.dart';
import 'package:dsync/app/features/device_detail/device_detail_view_state.dart';
import 'package:dsync/app/features/device_detail/peer_probe.dart';
import 'package:dsync/app/features/run_setup/folder_picker.dart';
import 'package:dsync/app/format_path.dart';
import 'package:dsync/app/paired_device_row.dart';
import 'package:dsync/dsync_core/identity/paired_device_store.dart';
import 'package:dsync/dsync_core/identity/self_signed_certificate.dart';
import 'package:dsync/dsync_core/models/device_identity.dart';
import 'package:dsync/dsync_core/models/paired_device.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// The Device page as a rendering test: rows are pushed into `AppState`
/// already rendered and the page is pumped directly, per the scope
/// contract. What a write does to the store is
/// `device_detail_controller_test.dart`'s.
void main() {
  late Directory tempDir;
  late AppController app;
  late DeviceDetailController controller;
  late _FakeProbe probe;
  late PairedDevice phone;
  var gone = 0;

  setUpAll(() {
    // The one paired device these tests write against, under a real
    // certificate: `deviceId` is the hash of its key, so the rows pushed
    // into `AppState` have to carry the id the store will answer to.
    phone = PairedDevice(
      certificatePem: generateDeviceIdentity(commonName: 'desktop')
          .certificatePem,
      name: 'desktop',
      agreedReplicaRoots: const {'/home/me/notes'},
      pairedAt: DateTime(2026, 9, 15),
      lastKnownAddress: PeerAddress(host: '10.0.0.7', port: 28771),
    );
  });

  setUp(() async {
    // A real state dir per test, because the check's reachable case writes
    // the address it reached through to the store — the same
    // `recordConnection` a run's dial writes.
    tempDir = await Directory.systemTemp.createTemp('device_detail_page_test');
    await PairedDeviceStore(File('${tempDir.path}/dsync/paired-devices.json'))
        .add(phone);
    app = AppController(() async => AppPaths(tempDir.path), now: DateTime.now);
    probe = _FakeProbe();
    controller = DeviceDetailController(
      app,
      environment: const {'HOME': '/home/me'},
      picker: _NoPicker(),
      probe: probe,
    );
    appScope.setController(app);
    deviceDetailScope.setController(controller);
    gone = 0;
  });

  tearDown(appScope.reset);
  tearDown(deviceDetailScope.reset);
  tearDown(() => controller.dispose());
  tearDown(() => tempDir.delete(recursive: true));

  PairedDeviceRow row({
    List<String> agreedRoots = const ['/home/me/notes'],
    String? certificateWarning,
  }) => PairedDeviceRow(
    name: 'desktop',
    deviceId: phone.deviceId,
    address: '10.0.0.7:28771',
    pairedAt: DateTime(2026, 9, 15),
    agreedRootLabels: {for (final root in agreedRoots) root: elidePath(root)},
    certificateIssuedAt: DateTime(2026, 1, 15),
    certificateExpiresAt: DateTime(2027, 1, 15),
    certificateWarning: certificateWarning,
  );

  /// Brings an action below the fold into the tree: the page is a
  /// `ListView`, which does not build what it has not scrolled to.
  Future<void> scrollTo(WidgetTester tester, Key key) =>
      tester.scrollUntilVisible(
        find.byKey(key),
        200,
        scrollable: find.byType(Scrollable).first,
      );

  /// Taps an action below the fold: the page is a `ListView` and the
  /// actions at its bottom are not built until they are scrolled to —
  /// and `scrollUntilVisible` stops as soon as an edge of the target is
  /// on screen, which is not enough for a tap to hit it, so the target is
  /// brought fully into view before the tap.
  Future<void> tapAction(WidgetTester tester, Key key) async {
    await scrollTo(tester, key);
    await tester.ensureVisible(find.byKey(key));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(key));
    await tester.pumpAndSettle();
  }

  /// Taps an action whose work is real I/O — reading this device's
  /// identity, writing the store — and waits for the outcome it renders.
  ///
  /// A widget test's own zone fakes time, so `pumpAndSettle` can return
  /// with a `dart:io` future still outstanding and the page still idle;
  /// `runAsync` is what lets the real event loop deliver it. Alternating
  /// the two is what carries an action from tap to rendered line. Bounded,
  /// so an action that never lands fails the expectation rather than
  /// hanging the suite.
  Future<void> awaitOutcome(WidgetTester tester, Key key) async {
    await tester.tap(find.byKey(key));
    for (var i = 0; i < 200; i++) {
      await tester.pumpAndSettle();
      if (controller.state.outcome is! DeviceDetailIdle) return;
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
    }
  }

  /// Scrolls back to the top, where the page's outcome line is: a
  /// `ListView` does not keep the rows it has scrolled past, so an action
  /// taken below the fold has to be read back up there.
  Future<void> scrollToOutcome(WidgetTester tester) =>
      tester.scrollUntilVisible(
        find.byKey(const Key('device-detail-id')),
        -200,
        scrollable: find.byType(Scrollable).first,
      );

  Future<void> pumpPage(WidgetTester tester) => tester.pumpWidget(
    MaterialApp(
      home: DeviceDetailPage(deviceId: phone.deviceId, onGone: () => gone++),
    ),
  );

  testWidgets('shows the address, the pairing date and the certificate', (
    tester,
  ) async {
    app.state.recordDevices([row()]);

    await pumpPage(tester);

    expect(find.textContaining('10.0.0.7:28771'), findsOneWidget);
    expect(find.textContaining('paired 2026-09-15'), findsOneWidget);
    expect(find.text('issued 2026-01-15 · expires 2027-01-15'), findsOneWidget);
    expect(find.byKey(const Key('device-detail-id')), findsOneWidget);
  });

  testWidgets('lists every shared folder, each with a way to withdraw it', (
    tester,
  ) async {
    app.state.recordDevices([
      row(agreedRoots: const ['/home/me/notes', '/home/me/photos']),
    ]);

    await pumpPage(tester);
    await scrollTo(tester, const Key('device-root-/home/me/photos'));

    expect(find.byKey(const Key('device-root-/home/me/notes')), findsOneWidget);
    expect(
      find.byKey(const Key('device-root-/home/me/photos')),
      findsOneWidget,
    );
    expect(find.byTooltip('Stop sharing'), findsNWidgets(2));
  });

  testWidgets('a long folder keeps its end, not its shared prefix', (
    tester,
  ) async {
    const long = '/storage/emulated/0/Android/data/dev.dsync/files/notes';
    app.state.recordDevices([
      row(agreedRoots: const [long]),
    ]);

    await pumpPage(tester);
    await scrollTo(tester, const Key('device-root-$long'));

    // The row is keyed by the stored path — what a withdrawal is addressed
    // by — but reads as the elided label, which keeps the leaf.
    expect(find.text(long), findsNothing);
    expect(find.text(elidePath(long)), findsOneWidget);
    expect(find.textContaining('notes'), findsWidgets);
  });

  testWidgets('a device with no grants says so, rather than showing nothing', (
    tester,
  ) async {
    app.state.recordDevices([row(agreedRoots: const [])]);

    await pumpPage(tester);
    await scrollTo(tester, const Key('device-grant-root'));

    expect(find.text('No folders shared with this device.'), findsOneWidget);
  });

  testWidgets('the folders section sits below the pairing-wide revoke', (
    tester,
  ) async {
    app.state.recordDevices([row()]);
    await pumpPage(tester);

    await scrollTo(tester, const Key('device-root-/home/me/notes'));

    // Overshooting a folder's withdraw must not land on the revoke of the
    // whole pairing, so the growing list is last and the revoke is above
    // the section header.
    expect(
      tester.getTopLeft(find.byKey(const Key('device-revoke'))).dy,
      lessThan(
        tester
            .getTopLeft(find.byKey(const Key('device-root-/home/me/notes')))
            .dy,
      ),
    );
  });

  testWidgets('the grant dialog leads with the chooser and still takes a '
      'typed path', (tester) async {
    app.state.recordDevices([row()]);
    await pumpPage(tester);

    await tapAction(tester, const Key('device-grant-root'));

    expect(find.byKey(const Key('device-grant-path-field')), findsOneWidget);
    final browse = find.byKey(const Key('device-grant-browse'));
    expect(browse, findsOneWidget);
    // The chooser is the filled button; typing is the fallback under it.
    expect(tester.widget(browse), isA<FilledButton>());
  });

  testWidgets('withdrawing a folder asks first, and a cancel keeps it', (
    tester,
  ) async {
    app.state.recordDevices([row()]);
    await pumpPage(tester);

    await tapAction(tester, const Key('device-withdraw-/home/me/notes'));
    expect(find.text('Stop sharing /home/me/notes?'), findsOneWidget);
    expect(find.textContaining('desktop is not told'), findsOneWidget);
    expect(find.textContaining('next time it asks for it'), findsOneWidget);

    await tester.tap(find.byKey(const Key('withdraw-root-cancel')));
    await tester.pumpAndSettle();

    expect(controller.state.outcome, isA<DeviceDetailIdle>());
    expect(find.byKey(const Key('device-root-/home/me/notes')), findsOneWidget);
  });

  testWidgets('a confirmed withdrawal writes and reports the folder', (
    tester,
  ) async {
    app.state.recordDevices([row()]);
    await pumpPage(tester);

    await tapAction(tester, const Key('device-withdraw-/home/me/notes'));
    await awaitOutcome(tester, const Key('withdraw-root-confirm'));
    await scrollToOutcome(tester);

    expect(
      find.textContaining('No longer sharing /home/me/notes'),
      findsOneWidget,
    );
  });

  testWidgets('the rename dialog opens filled with the current name', (
    tester,
  ) async {
    app.state.recordDevices([row()]);
    await pumpPage(tester);

    await tester.tap(find.byKey(const Key('device-rename')));
    await tester.pumpAndSettle();

    final field = tester.widget<TextField>(
      find.byKey(const Key('device-name-field')),
    );
    expect(field.controller!.text, 'desktop');
  });

  testWidgets('the address dialog opens filled with the address on file', (
    tester,
  ) async {
    app.state.recordDevices([row()]);
    await pumpPage(tester);

    await tapAction(tester, const Key('device-address'));

    final field = tester.widget<TextField>(
      find.byKey(const Key('device-address-field')),
    );
    expect(field.controller!.text, '10.0.0.7:28771');
  });

  testWidgets('a saved address is written through and shown back', (
    tester,
  ) async {
    app.state.recordDevices([row()]);
    await pumpPage(tester);

    await tapAction(tester, const Key('device-address'));
    await tester.enterText(
      find.byKey(const Key('device-address-field')),
      '10.0.0.9:9100',
    );
    await awaitOutcome(tester, const Key('device-address-confirm'));
    await scrollToOutcome(tester);
    expect(find.textContaining('reached at 10.0.0.9:9100'), findsOneWidget);
    expect(find.textContaining('10.0.0.9:9100'), findsWidgets);
  });

  testWidgets('an address that will not parse is refused, not written', (
    tester,
  ) async {
    app.state.recordDevices([row()]);
    await pumpPage(tester);

    await tapAction(tester, const Key('device-address'));
    await tester.enterText(
      find.byKey(const Key('device-address-field')),
      '10.0.0.9:http',
    );
    await awaitOutcome(tester, const Key('device-address-confirm'));
    await scrollToOutcome(tester);
    expect(find.textContaining('Not a valid address'), findsOneWidget);
    expect(find.textContaining('10.0.0.7:28771'), findsOneWidget);
  });

  testWidgets('a reachable peer reports where it was reached', (tester) async {
    app.state.recordDevices([row()]);
    await pumpPage(tester);

    await scrollTo(tester, const Key('device-test-connection'));
    await awaitOutcome(tester, const Key('device-test-connection'));
    await scrollToOutcome(tester);
    expect(find.text('Reached desktop at 10.0.0.7:28771.'), findsOneWidget);
  });

  testWidgets('an unreachable peer says so, with the address it tried', (
    tester,
  ) async {
    probe.result = const PeerUnreachable('Connection refused');
    app.state.recordDevices([row()]);
    await pumpPage(tester);

    await scrollTo(tester, const Key('device-test-connection'));
    await awaitOutcome(tester, const Key('device-test-connection'));
    await scrollToOutcome(tester);
    expect(
      find.textContaining('Could not reach desktop at 10.0.0.7:28771'),
      findsOneWidget,
    );
  });

  testWidgets('a certificate that is not the pinned one gets its own line', (
    tester,
  ) async {
    probe.result = const PeerCertificateRefused('unknown certificate');
    app.state.recordDevices([row()]);
    await pumpPage(tester);

    await scrollTo(tester, const Key('device-test-connection'));
    await awaitOutcome(tester, const Key('device-test-connection'));
    await scrollToOutcome(tester);
    expect(
      find.textContaining('did not present the certificate'),
      findsOneWidget,
    );
    expect(find.textContaining('Could not reach'), findsNothing);
  });

  testWidgets('revoke asks first and says it is one-sided', (tester) async {
    app.state.recordDevices([row()]);
    await pumpPage(tester);

    await tapAction(tester, const Key('device-revoke'));

    expect(find.text('Revoke desktop?'), findsOneWidget);
    expect(
      find.textContaining('still trusts this device until you revoke'),
      findsOneWidget,
    );
  });

  testWidgets('a revoked device leaves through onGone, not by popping', (
    tester,
  ) async {
    app.state.recordDevices([row()]);
    await pumpPage(tester);

    app.state.recordDevices(const []);
    await tester.pump();

    expect(find.text('This device is no longer paired.'), findsOneWidget);
    await tester.tap(find.byKey(const Key('device-detail-back')));
    expect(gone, 1);
  });

  testWidgets('an outcome renders as a line on the page', (tester) async {
    app.state.recordDevices([row()]);
    await pumpPage(tester);

    controller.state.recordOutcome(
      const DeviceDetailFailed('a device named "laptop" is already paired'),
    );
    await tester.pump();

    expect(find.textContaining('already paired'), findsOneWidget);
  });

  testWidgets('shows the peer certificate warning when there is one', (
    tester,
  ) async {
    app.state.recordDevices([
      row(certificateWarning: 'certificate for desktop expires in 3 days'),
    ]);

    await pumpPage(tester);

    expect(find.textContaining('expires in 3 days'), findsOneWidget);
  });
}

/// A `PeerProbe` that answers with whatever the test set, so the check runs
/// with no socket at all.
class _FakeProbe implements PeerProbe {
  PeerProbeResult result = const PeerReachable();

  @override
  Future<PeerProbeResult> probe({
    required PeerAddress address,
    required String expectedPeerDeviceId,
    required DeviceIdentity ownIdentity,
    required DateTime now,
  }) async => result;
}

/// The page never opens the chooser in these tests; a picker that would
/// throw makes that explicit rather than leaving a plugin call reachable.
class _NoPicker implements FolderPicker {
  @override
  Future<String?> pick() async => throw UnimplementedError();

  @override
  Future<bool> requestAccess() async => false;

  @override
  Future<void> openSettings() async {}
}
