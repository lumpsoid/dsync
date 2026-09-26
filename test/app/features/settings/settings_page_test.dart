import 'dart:io';

import 'package:dsync/app/app_controller.dart';
import 'package:dsync/app/app_scope.dart';
import 'package:dsync/app/features/settings/settings_controller.dart';
import 'package:dsync/app/features/settings/settings_page.dart';
import 'package:dsync/app/features/settings/settings_scope.dart';
import 'package:dsync/app/features/settings/settings_view_state.dart';
import 'package:dsync/app/rust/bindings/bindings.dart' as wire;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fake_hub.dart';
import '../../support/fake_head.dart';

/// The Settings page as a rendering test: the view state is written
/// directly and the page is pumped, per the scope contract. Nothing here
/// decides what a bind address may be — that is
/// `settings_controller_test.dart`'s.
void main() {
  late Directory tempDir;
  late AppController app;
  late _RecordingController controller;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('settings_page_test');
    final core = FakeHub()
      ..reply<wire.CoreCommandInit>(
        initialised(
          stateDir: tempDir.path,
          profilesDir: '${tempDir.path}/profiles',
        ),
      );
    app = fakeApp(core);
    controller = _RecordingController(app);
    appScope.setController(app);
    settingsScope.setController(controller);
  });

  tearDown(appScope.reset);
  tearDown(settingsScope.reset);
  tearDown(() async {
    controller.dispose();
    await tempDir.delete(recursive: true);
  });

  Future<void> pumpPage(WidgetTester tester) =>
      tester.pumpWidget(const MaterialApp(home: SettingsPage()));

  testWidgets('shows the Network section and the stored address', (
    tester,
  ) async {
    controller.state.recordBindAddress('10.8.0.3');

    await pumpPage(tester);

    expect(find.text('Network'), findsOneWidget);
    expect(find.text('Pairing bind address'), findsOneWidget);
    expect(find.textContaining('10.8.0.3'), findsOneWidget);
  });

  testWidgets('asks the controller to read the store on mounting', (
    tester,
  ) async {
    await pumpPage(tester);

    expect(controller.loads, 1);
  });

  testWidgets('a typed address is handed to the controller', (tester) async {
    controller.state.recordBindAddress('0.0.0.0');
    await pumpPage(tester);

    await tester.tap(find.byKey(const Key('settings-bind-address')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('settings-bind-address-field')),
      '10.8.0.3',
    );
    await tester.tap(find.byKey(const Key('settings-bind-address-save')));
    await tester.pumpAndSettle();

    expect(controller.saved, ['10.8.0.3']);
  });

  testWidgets('cancelling the dialog stores nothing', (tester) async {
    controller.state.recordBindAddress('0.0.0.0');
    await pumpPage(tester);

    await tester.tap(find.byKey(const Key('settings-bind-address')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    expect(controller.saved, isEmpty);
  });

  testWidgets('a refusal is shown as the page\'s error line', (tester) async {
    controller.state.recordBindAddress('0.0.0.0');
    controller.state.recordOutcome(
      const SettingsFailed('"my-laptop" is not an IP address.'),
    );

    await pumpPage(tester);

    expect(find.textContaining('is not an IP address'), findsOneWidget);
  });

  testWidgets('a damaged store leaves no value and shows the reason', (
    tester,
  ) async {
    controller.state.recordOutcome(
      const SettingsFailed('Settings file at /tmp/settings.json is damaged'),
    );

    await pumpPage(tester);

    expect(find.textContaining('is damaged'), findsOneWidget);
    expect(find.textContaining('Unavailable'), findsOneWidget);
  });
}

/// A controller that records what the page asked of it instead of touching
/// a store: the page's job here is to carry a tap and a typed value down,
/// and to render what the view state says.
class _RecordingController extends SettingsController {
  _RecordingController(super.app);

  int loads = 0;
  final saved = <String>[];

  @override
  Future<void> load() async => loads++;

  @override
  Future<void> saveBindAddress(String text) async => saved.add(text);
}
