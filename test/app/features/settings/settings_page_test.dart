import 'dart:io';

import 'package:dsync/app/app_controller.dart';
import 'package:dsync/app/app_scope.dart';
import 'package:dsync/app/app_theme.dart';
import 'package:dsync/app/app_settings.dart';
import 'package:dsync/app/features/settings/settings_controller.dart';
import 'package:dsync/app/features/settings/settings_page.dart';
import 'package:dsync/app/features/settings/settings_scope.dart';
import 'package:dsync/app/features/settings/settings_view_state.dart';
import 'package:dsync/app/mass_delete_guard.dart';
import 'package:dsync/app/peer_port.dart';
import 'package:dsync/app/theme_preference.dart';
import 'package:dsync/app/readable_width.dart';
import 'package:dsync/app/rust/bindings/bindings.dart' as wire;
import 'package:dsync/app/warn_size.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/affordances.dart';
import '../../support/clipboard.dart';
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

  testWidgets('shows this build\'s version, or unknown until it is read', (
    tester,
  ) async {
    controller.state.recordSettings(at('0.0.0.0'));
    await pumpPage(tester);
    final version = find.byKey(const Key('settings-version'));
    await tester.scrollUntilVisible(version, 200);

    expect(
      find.descendant(of: version, matching: find.text('Unknown')),
      findsOneWidget,
    );

    controller.state.recordVersion('0.1.0 (2d2ca38)');
    await tester.pump();

    expect(
      find.descendant(of: version, matching: find.text('0.1.0 (2d2ca38)')),
      findsOneWidget,
    );
  });

  testWidgets('Copy diagnostics puts the core\'s text on the clipboard', (
    tester,
  ) async {
    final copied = recordClipboard(tester);
    controller.state.recordSettings(at('0.0.0.0'));
    await pumpPage(tester);

    await tester.scrollUntilVisible(
      find.byKey(const Key('settings-copy-diagnostics')),
      200,
    );
    await tester.ensureVisible(
      find.byKey(const Key('settings-copy-diagnostics')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('settings-copy-diagnostics')));
    await tester.pumpAndSettle();

    expect(copied, ['dsync 0.1.0 on linux x86_64\n\nNothing logged yet.\n']);
    expect(find.text('Diagnostics copied.'), findsOneWidget);
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

  testWidgets('shows the warn size off, then the stored one, in the Sync '
      'section', (tester) async {
    controller.state.recordSettings(AppSettings.defaults);
    await pumpPage(tester);
    await tester.scrollUntilVisible(
      find.byKey(const Key('settings-warn-size')),
      100,
    );

    expect(find.text('Warn about large transfers'), findsOneWidget);
    expect(find.textContaining('Off'), findsOneWidget);

    controller.state.recordSettings(
      AppSettings.defaults.withWarnSize(WarnSizeAbove(1048576)),
    );
    await tester.pump();
    expect(find.textContaining('Above 1 MiB'), findsOneWidget);

    controller.state.recordSettings(
      AppSettings.defaults.withWarnSize(WarnSizeAbove(1234567)),
    );
    await tester.pump();
    expect(find.textContaining('Above 1.2 MiB'), findsOneWidget);
  });

  testWidgets('a typed warn size is handed to the controller', (tester) async {
    controller.state.recordSettings(
      AppSettings.defaults.withWarnSize(WarnSizeAbove(5000)),
    );
    await pumpPage(tester);
    await tester.scrollUntilVisible(
      find.byKey(const Key('settings-warn-size')),
      100,
    );

    await tester.tap(find.byKey(const Key('settings-warn-size')));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<TextField>(find.byKey(const Key('settings-warn-size-field')))
          .controller!
          .text,
      '5 KB',
    );
    await tester.enterText(
      find.byKey(const Key('settings-warn-size-field')),
      '',
    );
    await tester.tap(find.byKey(const Key('settings-warn-size-save')));
    await tester.pumpAndSettle();

    expect(controller.warnSizes, ['']);
  });

  testWidgets('shows the delete guard\'s thresholds in the Deletion safety '
      'section, saying it always asks past them', (tester) async {
    controller.state.recordSettings(
      AppSettings.defaults.withMassDeleteGuard(
        MassDeleteGuard(minFiles: 3, percent: 20),
      ),
    );
    await pumpPage(tester);
    await tester.scrollUntilVisible(
      find.byKey(const Key('settings-mass-delete-percent')),
      100,
    );

    expect(find.text('Deletion safety'), findsOneWidget);
    expect(find.textContaining('3 files on one side'), findsOneWidget);
    expect(find.textContaining('20% of its files'), findsOneWidget);
    expect(find.textContaining('it always asks past them'), findsOneWidget);
    expect(find.byType(Switch), findsOneWidget, reason: 'keep-awake only');
  });

  testWidgets('typed thresholds are handed to the controller', (tester) async {
    controller.state.recordSettings(AppSettings.defaults);
    // Tall enough for every section at once.
    tester.view.physicalSize = const Size(800, 1800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await pumpPage(tester);

    for (final (key, typed) in [
      ('settings-mass-delete-min-files', '3'),
      ('settings-mass-delete-percent', '20'),
    ]) {
      await tester.tap(find.byKey(Key(key)));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(Key('$key-field')), typed);
      await tester.tap(find.byKey(Key('$key-save')));
      await tester.pumpAndSettle();
    }

    expect(controller.massDeleteMinFiles, ['3']);
    expect(controller.massDeletePercents, ['20']);
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
    // Tall enough for every section and the notice under them at once.
    tester.view.physicalSize = const Size(800, 1800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await pumpPage(tester);

    expect(find.textContaining('is damaged'), findsOneWidget);
    // Every setting: none shows a default the file did not say.
    expect(find.textContaining('Unavailable'), findsNWidgets(7));
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

  final warnSizes = <String>[];

  @override
  Future<void> saveWarnSize(String text) async => warnSizes.add(text);

  final massDeleteMinFiles = <String>[];

  @override
  Future<void> saveMassDeleteMinFiles(String text) async =>
      massDeleteMinFiles.add(text);

  final massDeletePercents = <String>[];

  @override
  Future<void> saveMassDeletePercent(String text) async =>
      massDeletePercents.add(text);
}
