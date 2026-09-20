import 'dart:io';

import 'package:dsync/app/app_controller.dart';
import 'package:dsync/app/app_paths.dart';
import 'package:dsync/app/app_scope.dart';
import 'package:dsync/app/features/run_setup/folder_picker.dart';
import 'package:dsync/app/features/shared_folders/shared_folders_controller.dart';
import 'package:dsync/app/features/shared_folders/shared_folders_page.dart';
import 'package:dsync/app/features/shared_folders/shared_folders_scope.dart';
import 'package:dsync/app/features/shared_folders/shared_folders_view_state.dart';
import 'package:dsync/app/format_path.dart';
import 'package:dsync/app/paired_device_row.dart';
import 'package:dsync/dsync_core/identity/paired_device_store.dart';
import 'package:dsync/dsync_core/identity/self_signed_certificate.dart';
import 'package:dsync/dsync_core/models/paired_device.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// The Shared folders page as a rendering test: devices are pushed into
/// `AppState` already rendered and the page is pumped directly, per the
/// scope contract. What a toggle does to the store is
/// `shared_folders_controller_test.dart`'s.
void main() {
  late Directory tempDir;
  late AppController app;
  late SharedFoldersController controller;
  late _FakePicker picker;
  late PairedDevice desktop;
  late PairedDevice laptop;

  setUpAll(() {
    desktop = PairedDevice(
      certificatePem: generateDeviceIdentity(commonName: 'desktop')
          .certificatePem,
      name: 'desktop',
      agreedReplicaRoots: const {'/home/me/notes'},
      pairedAt: DateTime(2026, 9, 15),
      lastKnownAddress: PeerAddress(host: '10.0.0.7', port: 28771),
    );
    laptop = PairedDevice(
      certificatePem: generateDeviceIdentity(commonName: 'laptop')
          .certificatePem,
      name: 'laptop',
      agreedReplicaRoots: const {},
      pairedAt: DateTime(2026, 9, 15),
      lastKnownAddress: PeerAddress(host: '10.0.0.8', port: 28771),
    );
  });

  setUp(() async {
    // A real state dir, because a toggle writes through `AppController` to
    // a real `PairedDeviceStore` — the page under test is the only fake-free
    // path to it.
    tempDir = await Directory.systemTemp.createTemp('shared_folders_page_test');
    final store = PairedDeviceStore(
      File('${tempDir.path}/dsync/paired-devices.json'),
    );
    await store.add(desktop);
    await store.add(laptop);
    app = AppController(
      () async =>
          AppPaths(tempDir.path, documentsDir: '${tempDir.path}/documents'),
      now: DateTime.now,
    );
    picker = _FakePicker();
    controller = SharedFoldersController(
      app,
      environment: const {'HOME': '/home/me'},
      picker: picker,
    );
    appScope.setController(app);
    sharedFoldersScope.setController(controller);
  });

  tearDown(appScope.reset);
  tearDown(sharedFoldersScope.reset);
  tearDown(() => controller.dispose());
  tearDown(() => tempDir.delete(recursive: true));

  PairedDeviceRow row(
    PairedDevice device, {
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
  );

  Future<void> pumpPage(WidgetTester tester) =>
      tester.pumpWidget(const MaterialApp(home: SharedFoldersPage()));

  /// Taps a widget and waits for the write behind it to land: a widget
  /// test's own zone fakes time, so `pumpAndSettle` can return with a
  /// `dart:io` future still outstanding. Bounded, so an action that never
  /// lands fails an expectation rather than hanging the suite.
  Future<void> tapAndAwait(WidgetTester tester, Finder finder) async {
    await tester.tap(finder);
    for (var i = 0; i < 200; i++) {
      await tester.pumpAndSettle();
      if (controller.state.outcome is! SharedFoldersIdle) return;
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
    }
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

  /// Carries an action whose writes are several — one grant per device —
  /// past the first outcome: the loop above stops at the first, and the
  /// rest of the grants are still in flight behind it.
  Future<void> settleWrites(WidgetTester tester) async {
    for (var i = 0; i < 20; i++) {
      await tester.pumpAndSettle();
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
    }
    await tester.pumpAndSettle();
  }

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
    await settleWrites(tester);

    // Typed `~` is expanded the way `dsync pair grant` expands it.
    expect(
      find.byKey(const Key('shared-folder-/home/me/Sync')),
      findsOneWidget,
    );
    expect(
      find.text('desktop and laptop may reach this folder.'),
      findsOneWidget,
    );
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
