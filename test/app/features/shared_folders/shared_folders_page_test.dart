import 'package:dsync/app/app_controller.dart';
import 'package:dsync/app/app_scope.dart';
import 'package:dsync/app/core_link/models/paired_device_info.dart';
import 'package:dsync/app/features/run_setup/folder_picker.dart';
import 'package:dsync/app/features/shared_folders/shared_folders_controller.dart';
import 'package:dsync/app/features/shared_folders/shared_folders_page.dart';
import 'package:dsync/app/features/shared_folders/shared_folders_scope.dart';
import 'package:dsync/app/features/shared_folders/shared_folders_view_state.dart';
import 'package:dsync/app/format_path.dart';
import 'package:dsync/app/paired_device_row.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fake_hub.dart';
import '../../support/fake_head.dart';
import '../../support/pump_until.dart';

/// The Shared folders page as a rendering test: devices are pushed into
/// `AppState` already rendered and the page is pumped directly, per the
/// scope contract. What a toggle does to the store is
/// `shared_folders_controller_test.dart`'s.
void main() {
  late AppController app;
  late SharedFoldersController controller;
  late _FakePicker picker;
  final desktop = pairedDevice(
    deviceId: 'desktop-id',
    name: 'desktop',
    grantedRoots: ['/home/me/notes'],
  );
  final laptop = pairedDevice(
    deviceId: 'laptop-id',
    name: 'laptop',
    address: '10.0.0.8:28771',
  );
  String? copied;

  setUp(() {
    // A toggle writes through `AppController` to the core — the page under
    // test is the only path to it here.
    app = fakeApp(FakeHub(devices: [desktop, laptop]));
    picker = _FakePicker();
    controller = SharedFoldersController(app, picker: picker);
    appScope.setController(app);
    sharedFoldersScope.setController(controller);
    copied = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
          if (call.method == 'Clipboard.setData') {
            copied = (call.arguments as Map)['text'] as String?;
          }
          return null;
        });
  });

  tearDown(
    () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null),
  );

  tearDown(appScope.reset);
  tearDown(sharedFoldersScope.reset);
  tearDown(() => controller.dispose());

  PairedDeviceRow row(
    PairedDeviceInfo device, {
    List<String> agreedRoots = const [],
  }) => PairedDeviceRow(
    name: device.name,
    deviceId: device.deviceId,
    address: '10.0.0.7:28771',
    pairedAt: DateTime(2026, 9, 15),
    agreedRootLabels: {for (final root in agreedRoots) root: elidePath(root)},
    certificateIssuedAt: DateTime(2026, 1, 1),
    certificateExpiresAt: DateTime(2027, 1, 1),
    certificateWarning: null,
    verifiedAt: null,
  );

  Future<void> pumpPage(WidgetTester tester) =>
      tester.pumpWidget(const MaterialApp(home: SharedFoldersPage()));

  /// Taps a widget and waits for the write behind it to land, then settles
  /// so a dialog the tap closed has finished leaving.
  Future<void> tapAndAwait(WidgetTester tester, Finder finder) async {
    await tester.tap(finder);
    await pumpUntil(
      tester,
      () => controller.state.outcome is! SharedFoldersIdle,
      what: 'an outcome after the tap',
    );
    await tester.pumpAndSettle();
  }

  testWidgets('one row per folder, naming the devices that may reach it', (
    tester,
  ) async {
    app.state.recordDevices([
      row(desktop, agreedRoots: const ['/home/me/notes']),
      row(laptop),
    ]);

    await pumpPage(tester);

    expect(
      find.byKey(const Key('shared-folder-/home/me/notes')),
      findsOneWidget,
    );
    expect(find.text('Only desktop may reach this folder.'), findsOneWidget);
    // Every paired device is a toggle on the folder, including the one that
    // cannot reach it yet — that is how a grant is made here.
    expect(find.text('desktop'), findsOneWidget);
    expect(find.text('laptop'), findsOneWidget);
  });

  testWidgets('a long folder keeps its end, not its shared prefix', (
    tester,
  ) async {
    const long = '/storage/emulated/0/Android/data/dev.dsync/files/notes';
    app.state.recordDevices([
      row(desktop, agreedRoots: const [long]),
      row(laptop),
    ]);

    await pumpPage(tester);

    expect(find.text(long), findsNothing);
    expect(find.text(elidePath(long)), findsOneWidget);
  });

  testWidgets('copying a folder gives the stored path, not the label', (
    tester,
  ) async {
    const long = '/storage/emulated/0/Android/data/dev.dsync/files/notes';
    app.state.recordDevices([
      row(desktop, agreedRoots: const [long]),
      row(laptop),
    ]);
    await pumpPage(tester);

    await tester.tap(find.byKey(const Key('shared-folder-copy-$long')));
    await tester.pumpAndSettle();

    expect(copied, long);
    expect(find.text('Folder path copied.'), findsOneWidget);
  });

  testWidgets('says which of the two empty cases this is', (tester) async {
    app.state.recordDevices([row(desktop), row(laptop)]);
    await pumpPage(tester);
    expect(find.byKey(const Key('shared-folders-empty')), findsOneWidget);

    app.state.recordDevices(const []);
    await tester.pump();
    expect(find.byKey(const Key('shared-folders-no-devices')), findsOneWidget);
  });

  testWidgets('it never claims to know what a peer shares back', (
    tester,
  ) async {
    app.state.recordDevices([
      row(desktop, agreedRoots: const ['/home/me/notes']),
      row(laptop),
    ]);

    await pumpPage(tester);

    expect(
      find.textContaining('is its own decision, made there'),
      findsOneWidget,
    );
  });

  testWidgets('toggling a device on shares the folder with it', (tester) async {
    app.state.recordDevices([
      row(desktop, agreedRoots: const ['/home/me/notes']),
      row(laptop),
    ]);
    await pumpPage(tester);

    await tapAndAwait(
      tester,
      find.byKey(Key('shared-folder-/home/me/notes-${laptop.deviceId}')),
    );

    expect(
      find.textContaining('Sharing /home/me/notes with laptop'),
      findsOneWidget,
    );
    expect(
      find.text('desktop and laptop may reach this folder.'),
      findsOneWidget,
    );
  });

  testWidgets('toggling a device off asks first, and a cancel keeps it', (
    tester,
  ) async {
    app.state.recordDevices([
      row(desktop, agreedRoots: const ['/home/me/notes']),
      row(laptop),
    ]);
    await pumpPage(tester);

    await tester.tap(
      find.byKey(Key('shared-folder-/home/me/notes-${desktop.deviceId}')),
    );
    await tester.pumpAndSettle();

    expect(find.text('Stop sharing /home/me/notes?'), findsOneWidget);
    await tester.tap(find.byKey(const Key('withdraw-root-cancel')));
    await tester.pumpAndSettle();

    expect(controller.state.outcome, isA<SharedFoldersIdle>());
    expect(find.text('Only desktop may reach this folder.'), findsOneWidget);
  });

  testWidgets('the last device off takes the folder with it, and says so', (
    tester,
  ) async {
    app.state.recordDevices([
      row(desktop, agreedRoots: const ['/home/me/notes']),
      row(laptop),
    ]);
    await pumpPage(tester);
    // The row warns before the toggle, not after it.
    expect(find.textContaining('stops being listed here'), findsOneWidget);

    await tester.tap(
      find.byKey(Key('shared-folder-/home/me/notes-${desktop.deviceId}')),
    );
    await tester.pumpAndSettle();
    await tapAndAwait(tester, find.byKey(const Key('withdraw-root-confirm')));

    expect(find.textContaining('No device may reach it now'), findsOneWidget);
    expect(find.byKey(const Key('shared-folders-empty')), findsOneWidget);
  });

  testWidgets('the add dialog leads with the chooser and keeps a typed path', (
    tester,
  ) async {
    picker.picked = '/media/usb/sync';
    app.state.recordDevices([row(desktop), row(laptop)]);
    await pumpPage(tester);

    await tester.tap(find.byKey(const Key('shared-folders-add')));
    await tester.pumpAndSettle();
    final browse = find.byKey(const Key('shared-folders-browse'));
    expect(tester.widget(browse), isA<FilledButton>());

    // Choosing fills the field and leaves the dialog open: there are still
    // devices to tick, and a folder ticked for nobody is stored nowhere.
    await tester.tap(browse);
    await tester.pumpAndSettle();
    final field = tester.widget<TextField>(
      find.byKey(const Key('shared-folders-path-field')),
    );
    expect(field.controller?.text, '/media/usb/sync');
    expect(find.byKey(const Key('shared-folders-add-confirm')), findsOneWidget);
  });

  testWidgets('a folder added for two devices lands on both', (tester) async {
    app.state.recordDevices([row(desktop), row(laptop)]);
    await pumpPage(tester);

    await tester.tap(find.byKey(const Key('shared-folders-add')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('shared-folders-path-field')),
      '~/Sync',
    );
    await tester.tap(
      find.byKey(Key('shared-folders-pick-${desktop.deviceId}')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(Key('shared-folders-pick-${laptop.deviceId}')));
    await tester.pumpAndSettle();
    await tapAndAwait(
      tester,
      find.byKey(const Key('shared-folders-add-confirm')),
    );
    // The writes are several — one grant per device — and the outcome
    // above lands at the first; the line naming both is the last of them.
    final both = find.text('desktop and laptop may reach this folder.');
    await pumpUntil(
      tester,
      () => both.evaluate().isNotEmpty,
      what: 'the grant to land on both devices',
    );
    await tester.pumpAndSettle();

    // Handed to the core as typed; the core expands `~` the way
    // `dsync pair grant` does (the fake stores it as given).
    expect(find.byKey(const Key('shared-folder-~/Sync')), findsOneWidget);
    expect(both, findsOneWidget);
  });

  testWidgets('a folder added for nobody is refused, with the reason', (
    tester,
  ) async {
    app.state.recordDevices([row(desktop), row(laptop)]);
    await pumpPage(tester);

    await tester.tap(find.byKey(const Key('shared-folders-add')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('shared-folders-path-field')),
      '~/Sync',
    );
    await tapAndAwait(
      tester,
      find.byKey(const Key('shared-folders-add-confirm')),
    );

    expect(find.textContaining('at least one device'), findsOneWidget);
    expect(find.byKey(const Key('shared-folders-empty')), findsOneWidget);
  });
}

/// The platform chooser, faked: it is a platform channel, and
/// `FolderPicker` already is the interface over it.
class _FakePicker implements FolderPicker {
  String? picked;

  @override
  Future<String?> pick() async => picked;

  @override
  Future<bool> requestAccess() async => true;

  @override
  Future<void> openSettings() async {}
}
