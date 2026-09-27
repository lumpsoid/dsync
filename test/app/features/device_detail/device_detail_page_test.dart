import 'package:dsync/app/app_controller.dart';
import 'package:dsync/app/app_scope.dart';
import 'package:dsync/app/features/device_detail/device_detail_controller.dart';
import 'package:dsync/app/features/device_detail/device_detail_page.dart';
import 'package:dsync/app/features/device_detail/device_detail_scope.dart';
import 'package:dsync/app/features/device_detail/device_detail_view_state.dart';
import 'package:dsync/app/core_link/models/filter_row.dart';
import 'package:dsync/app/features/run_setup/folder_picker.dart';
import 'package:dsync/app/format_path.dart';
import 'package:dsync/app/paired_device_row.dart';
import 'package:dsync/app/rust/bindings/bindings.dart' as wire;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fake_hub.dart';
import '../../support/fake_head.dart';
import '../../support/pump_until.dart';
import '../../../support/fake_folder_picker.dart';

/// The Device page as a rendering test: rows are pushed into `AppState`
/// already rendered and the page is pumped directly, per the scope
/// contract. What a write does to the store is
/// `device_detail_controller_test.dart`'s.
void main() {
  late FakeHub core;
  late AppController app;
  late DeviceDetailController controller;
  final phone = pairedDevice(
    deviceId: 'a1b2-c3d4',
    name: 'desktop',
    grantedRoots: ['/home/me/notes'],
    address: '10.0.0.7:28771',
  );
  var gone = 0;

  setUp(() {
    core = FakeHub();
    app = fakeApp(core);
    controller = DeviceDetailController(app, picker: _NoPicker());
    appScope.setController(app);
    deviceDetailScope.setController(controller);
    gone = 0;
  });

  tearDown(appScope.reset);
  tearDown(deviceDetailScope.reset);
  tearDown(() => controller.dispose());

  PairedDeviceRow row({
    List<String> agreedRoots = const ['/home/me/notes'],
    String? certificateWarning,
    DateTime? verifiedAt,
  }) => PairedDeviceRow(
    name: 'desktop',
    deviceId: phone.deviceId,
    address: '10.0.0.7:28771',
    pairedAt: DateTime(2026, 9, 15),
    agreedRootLabels: {for (final root in agreedRoots) root: elidePath(root)},
    certificateIssuedAt: DateTime(2026, 1, 15),
    certificateExpiresAt: DateTime(2027, 1, 15),
    certificateWarning: certificateWarning,
    verifiedAt: verifiedAt,
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
  /// An outcome is Done or Failed, so leaving Idle is the whole of the
  /// action; the callers say which. Settled after, so a confirm dialog the
  /// tap closed has finished leaving.
  Future<void> awaitOutcome(WidgetTester tester, Key key) async {
    await tester.tap(find.byKey(key));
    await pumpUntil(
      tester,
      () => controller.state.outcome is! DeviceDetailIdle,
      what: 'an outcome after tapping $key',
    );
    await tester.pumpAndSettle();
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

  testWidgets('granting a file: the same chooser, then a browse, ends in '
      'root/path (D6, R4)', (tester) async {
    final picker = FakeFolderPicker()..onPick = () => '/media/usb';
    final fileController = DeviceDetailController(app, picker: picker);
    fileController.select(phone.deviceId);
    deviceDetailScope.setController(fileController);
    addTearDown(fileController.dispose);
    core.reply<wire.CoreCommandListFilterFolder>(
      folderRows(const [
        FilterRow(
          path: 'notes.txt',
          name: 'notes.txt',
          size: 12,
          isFolder: false,
          excludedBy: null,
          syncs: true,
        ),
      ]),
    );
    core.reply<wire.CoreCommandGrantRoot>(
      devicesReply([
        pairedDevice(
          deviceId: phone.deviceId,
          name: 'desktop',
          grantedRoots: const ['/home/me/notes', '/media/usb/notes.txt'],
        ),
      ]),
    );
    app.state.recordDevices([row()]);
    await pumpPage(tester);

    await tapAction(tester, const Key('device-grant-root'));
    await tester.tap(find.byKey(const Key('device-grant-browse-file')));
    await tester.pumpAndSettle();
    expect(find.text('notes.txt'), findsOneWidget);

    await tester.tap(find.byKey(const Key('file-chooser-row-notes.txt')));
    await tester.pumpAndSettle();

    expect(core.sent<wire.CoreCommandGrantRoot>(), [
      wire.CoreCommandGrantRoot(
        deviceId: phone.deviceId,
        path: '/media/usb/notes.txt',
      ),
    ]);
    expect(
      core.sent<wire.CoreCommandListFilterFolder>().single.ignore,
      isEmpty,
    );
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
    core.reply<wire.CoreCommandWithdrawGrant>(
      devicesReply([
        pairedDevice(
          deviceId: phone.deviceId,
          name: 'desktop',
          address: '10.0.0.7:28771',
        ),
      ]),
    );
    app.state.recordDevices([row()]);
    await pumpPage(tester);

    await tapAction(tester, const Key('device-withdraw-/home/me/notes'));
    await awaitOutcome(tester, const Key('withdraw-root-confirm'));
    await scrollToOutcome(tester);

    expect(core.sent<wire.CoreCommandWithdrawGrant>(), [
      wire.CoreCommandWithdrawGrant(
        deviceId: phone.deviceId,
        root: '/home/me/notes',
      ),
    ]);
    expect(find.byKey(const Key('device-root-/home/me/notes')), findsNothing);
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

  testWidgets('a rename shows in the title, not only in the body', (
    tester,
  ) async {
    core.reply<wire.CoreCommandRenameDevice>(
      devicesReply([
        pairedDevice(
          deviceId: phone.deviceId,
          name: 'laptop',
          grantedRoots: ['/home/me/notes'],
          address: '10.0.0.7:28771',
        ),
      ]),
    );
    app.state.recordDevices([row()]);
    await pumpPage(tester);
    final title = find.descendant(
      of: find.byType(AppBar),
      matching: find.byType(Text),
    );
    expect(tester.widget<Text>(title).data, 'desktop');

    await tester.tap(find.byKey(const Key('device-rename')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('device-name-field')),
      'laptop',
    );
    await awaitOutcome(tester, const Key('device-rename-confirm'));

    expect(tester.widget<Text>(title).data, 'laptop');
  });

  testWidgets('a device that lands after the first frame titles the page', (
    tester,
  ) async {
    await pumpPage(tester);
    final title = find.descendant(
      of: find.byType(AppBar),
      matching: find.byType(Text),
    );
    expect(tester.widget<Text>(title).data, 'Device');

    app.state.recordDevices([row()]);
    await tester.pump();

    expect(tester.widget<Text>(title).data, 'desktop');
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
    core.reply<wire.CoreCommandSetDeviceAddress>(
      devicesReply([
        pairedDevice(
          deviceId: phone.deviceId,
          name: 'desktop',
          grantedRoots: ['/home/me/notes'],
          address: '10.0.0.9:9100',
        ),
      ]),
    );
    app.state.recordDevices([row()]);
    await pumpPage(tester);

    await tapAction(tester, const Key('device-address'));
    await tester.enterText(
      find.byKey(const Key('device-address-field')),
      '10.0.0.9:9100',
    );
    await awaitOutcome(tester, const Key('device-address-confirm'));
    await scrollToOutcome(tester);
    expect(core.sent<wire.CoreCommandSetDeviceAddress>(), [
      wire.CoreCommandSetDeviceAddress(
        deviceId: phone.deviceId,
        address: '10.0.0.9:9100',
      ),
    ]);
    expect(find.textContaining('reached at 10.0.0.9:9100'), findsOneWidget);
    expect(find.textContaining('10.0.0.9:9100'), findsWidgets);
  });

  testWidgets('an address the core will not read is refused, not written', (
    tester,
  ) async {
    core
      ..reply<wire.CoreCommandSetDeviceAddress>(
        failed('"10.0.0.9:http" has no valid port'),
      )
      // The refusal re-reads the list, which still holds the device.
      ..reply<wire.CoreCommandListDevices>(devicesReply([phone]));
    app.state.recordDevices([row()]);
    await pumpPage(tester);

    await tapAction(tester, const Key('device-address'));
    await tester.enterText(
      find.byKey(const Key('device-address-field')),
      '10.0.0.9:http',
    );
    await awaitOutcome(tester, const Key('device-address-confirm'));
    await scrollToOutcome(tester);
    expect(find.textContaining('has no valid port'), findsOneWidget);
    expect(find.textContaining('10.0.0.7:28771'), findsOneWidget);
  });

  testWidgets('a reachable peer reports where it was reached', (tester) async {
    core
      ..reply<wire.CoreCommandProbePeer>(reached('10.0.0.7:28771'))
      ..reply<wire.CoreCommandSetDeviceAddress>(devicesReply([phone]));
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
    core.reply<wire.CoreCommandProbePeer>(
      const wire.ReplyResultPeerProbed(
        value: wire.ProbeOutcomeUnreachable(message: 'Connection refused'),
      ),
    );
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
    core.reply<wire.CoreCommandProbePeer>(
      const wire.ReplyResultPeerProbed(
        value: wire.ProbeOutcomeRefused(message: 'unknown certificate'),
      ),
    );
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

  testWidgets('the id check asks rather than offering a button to press', (
    tester,
  ) async {
    app.state.recordDevices([row()]);
    await pumpPage(tester);

    await tapAction(tester, const Key('device-verify'));

    expect(find.byKey(const Key('device-verify-id')), findsOneWidget);
    expect(
      find.textContaining('read the id on its This-device page'),
      findsOneWidget,
    );
    expect(find.byKey(const Key('device-verify-match')), findsOneWidget);
    expect(find.byKey(const Key('device-verify-differ')), findsOneWidget);
    // Nothing to clear until something has been confirmed.
    expect(find.byKey(const Key('device-verify-clear')), findsNothing);
  });

  testWidgets('an unconfirmed pairing shows no mark and no notice', (
    tester,
  ) async {
    app.state.recordDevices([row()]);

    await pumpPage(tester);

    expect(find.byKey(const Key('device-detail-verified')), findsNothing);
    expect(find.text('Check device id'), findsOneWidget);
  });

  testWidgets('a confirmed pairing carries the mark and the date', (
    tester,
  ) async {
    app.state.recordDevices([row(verifiedAt: DateTime(2026, 9, 20))]);

    await pumpPage(tester);

    expect(find.byKey(const Key('device-detail-verified')), findsOneWidget);
    await scrollTo(tester, const Key('device-verify'));
    expect(find.text('Device id confirmed'), findsOneWidget);
    expect(
      find.textContaining('You confirmed this id on 2026-09-20'),
      findsOneWidget,
    );
  });

  testWidgets('"they differ" writes nothing and says to re-pair', (
    tester,
  ) async {
    app.state.recordDevices([row()]);
    await pumpPage(tester);
    await tapAction(tester, const Key('device-verify'));

    await tester.tap(find.byKey(const Key('device-verify-differ')));
    await tester.pumpAndSettle();

    expect(controller.device!.isVerified, isFalse);
    await scrollToOutcome(tester);
    expect(
      find.textContaining('revoke it below and pair again'),
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

/// The page never opens the chooser in these tests; a picker that would
/// throw makes that explicit rather than leaving a plugin call reachable.
class _NoPicker implements FolderPicker {
  @override
  Future<String?> pick() async => throw UnimplementedError();

  @override
  Future<bool> requestAccess() async => false;

  @override
  Future<void> openSettings() async {}

  @override
  bool get asksForFileAccess => false;
}
