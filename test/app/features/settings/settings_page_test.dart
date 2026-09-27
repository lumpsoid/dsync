import 'dart:io';

import 'package:dsync/app/app_controller.dart';
import 'package:dsync/app/app_scope.dart';
import 'package:dsync/app/app_theme.dart';
import 'package:dsync/app/app_settings.dart';
import 'package:dsync/app/features/settings/settings_controller.dart';
import 'package:dsync/app/features/settings/settings_page.dart';
import 'package:dsync/app/features/settings/settings_scope.dart';
import 'package:dsync/app/features/settings/settings_view_state.dart';
import 'package:dsync/app/peer_port.dart';
import 'package:dsync/app/theme_preference.dart';
import 'package:dsync/app/readable_width.dart';
import 'package:dsync/app/rust/bindings/bindings.dart' as wire;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/affordances.dart';
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

  Future<void> pumpPage(WidgetTester tester) => tester.pumpWidget(
    MaterialApp(theme: appTheme(Brightness.light), home: const SettingsPage()),
  );

  testWidgets('every icon button says what it does, and every tappable '
      'keeps the arrow', (tester) async {
    controller.state.recordSettings(at('10.8.0.3'));
    await pumpPage(tester);

    await expectAffordances(tester);
  });

  testWidgets('shows the Network section and the stored address', (
    tester,
  ) async {
    controller.state.recordSettings(at('10.8.0.3'));

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
    controller.state.recordSettings(at('0.0.0.0'));
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

  testWidgets('shows the stored peer port in the Network section', (
    tester,
  ) async {
    controller.state.recordSettings(
      AppSettings.defaults.withPeerPort(PeerPort(9000)),
    );

    await pumpPage(tester);

    expect(find.text('Peer port'), findsOneWidget);
    expect(find.textContaining('9000'), findsOneWidget);
  });

  testWidgets('a typed port is handed to the controller', (tester) async {
    controller.state.recordSettings(AppSettings.defaults);
    await pumpPage(tester);

    await tester.tap(find.byKey(const Key('settings-peer-port')));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<TextField>(find.byKey(const Key('settings-peer-port-field')))
          .controller!
          .text,
      '28771',
    );
    await tester.enterText(
      find.byKey(const Key('settings-peer-port-field')),
      '9000',
    );
    await tester.tap(find.byKey(const Key('settings-peer-port-save')));
    await tester.pumpAndSettle();

    expect(controller.ports, ['9000']);
    expect(controller.saved, isEmpty);
  });

  testWidgets('cancelling the dialog stores nothing', (tester) async {
    controller.state.recordSettings(at('0.0.0.0'));
    await pumpPage(tester);

    await tester.tap(find.byKey(const Key('settings-bind-address')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    expect(controller.saved, isEmpty);
  });

  testWidgets('shows the Appearance section with the stored theme chosen', (
    tester,
  ) async {
    controller.state.recordSettings(
      AppSettings.defaults.withTheme(ThemePreference.dark),
    );

    await pumpPage(tester);

    expect(find.text('Appearance'), findsOneWidget);
    final choice = tester.widget<SegmentedButton<ThemePreference>>(
      find.byKey(const Key('settings-theme-choice')),
    );
    expect(choice.selected, {ThemePreference.dark});
  });

  testWidgets('a chosen theme is handed to the controller', (tester) async {
    controller.state.recordSettings(AppSettings.defaults);
    await pumpPage(tester);

    await tester.tap(find.text('Light'));
    await tester.pumpAndSettle();

    expect(controller.themes, [ThemePreference.light]);
  });

  testWidgets('a refusal is shown as the page\'s error line', (tester) async {
    controller.state.recordSettings(at('0.0.0.0'));
    controller.state.recordOutcome(
      const SettingsFailed('"my-laptop" is not an IP address.'),
    );

    await pumpPage(tester);
    // The line follows every section, below the test window's fold.
    await tester.scrollUntilVisible(
      find.textContaining('is not an IP address'),
      200,
    );

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
    // Every setting: none shows a default the file did not say.
    expect(find.textContaining('Unavailable'), findsNWidgets(4));
    expect(find.byType(Switch), findsNothing);
  });

  testWidgets('shows the Power section with the stored keep-awake switch', (
    tester,
  ) async {
    controller.state.recordSettings(
      AppSettings.defaults.withKeepScreenAwake(false),
    );

    await pumpPage(tester);

    expect(find.text('Power'), findsOneWidget);
    expect(
      find.text('Keep screen awake during runs and serve'),
      findsOneWidget,
    );
    expect(tester.widget<Switch>(find.byType(Switch)).value, isFalse);
  });

  testWidgets('a flipped switch is handed to the controller', (tester) async {
    controller.state.recordSettings(AppSettings.defaults);
    await pumpPage(tester);

    await tester.tap(find.byKey(const Key('settings-keep-screen-awake')));
    await tester.pump();

    expect(controller.keepScreenAwake, [false]);
  });

  group('width', () {
    /// Pumps the page into a [width]-wide window, reset after the test.
    Future<void> pumpAt(WidgetTester tester, double width) async {
      tester.view.physicalSize = Size(width, 1440);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      controller.state.recordSettings(at('10.8.0.3'));
      await pumpPage(tester);
    }

    Rect row(WidgetTester tester) =>
        tester.getRect(find.byKey(const Key('settings-bind-address')));

    testWidgets('a wide window holds the rows to a centred list column', (
      tester,
    ) async {
      await pumpAt(tester, 2560);

      expect(row(tester).width, ReadableWidth.list.maxWidth);
      expect(row(tester).center.dx, 1280);
    });

    testWidgets('a phone keeps the rows as wide as the window', (tester) async {
      await pumpAt(tester, 400);

      expect(row(tester).left, 0);
      expect(row(tester).width, 400);
    });
  });
}

/// The defaults with the bind address [address], as the store would answer.
AppSettings at(String address) =>
    AppSettings.defaults.withBindAddress(InternetAddress(address));

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

  final themes = <ThemePreference>[];

  @override
  Future<void> saveTheme(ThemePreference theme) async => themes.add(theme);

  final keepScreenAwake = <bool>[];

  final ports = <String>[];

  @override
  Future<void> savePeerPort(String text) async => ports.add(text);

  @override
  Future<void> saveKeepScreenAwake(bool on) async => keepScreenAwake.add(on);
}
