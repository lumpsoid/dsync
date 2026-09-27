import 'dart:io';

import 'package:dsync/app/app_controller.dart';
import 'package:dsync/app/features/settings/settings_controller.dart';
import 'package:dsync/app/features/settings/settings_view_state.dart';
import 'package:dsync/app/rust/bindings/bindings.dart' as wire;
import 'package:dsync/app/theme_preference.dart';
import 'package:test/test.dart';

import '../../support/fake_hub.dart';
import '../../support/fake_head.dart';

/// `SettingsController` against a real settings store in a temporary state
/// directory: what it accepts, what it refuses, and what the page is left
/// showing either way.
void main() {
  late Directory tempDir;
  late AppController app;
  late SettingsController controller;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('settings_controller_test');
    final core = FakeHub()
      ..reply<wire.CoreCommandInit>(
        initialised(
          stateDir: tempDir.path,
          profilesDir: '${tempDir.path}/profiles',
        ),
      );
    app = fakeApp(core);
    controller = SettingsController(app);
  });

  tearDown(() async {
    controller.dispose();
    await tempDir.delete(recursive: true);
  });

  Future<File> settingsFile() async =>
      File('${(await app.dirs).stateDir}/settings.json');

  group('load', () {
    test('shows the default bind address on a first run', () async {
      await controller.load();

      expect(controller.state.settings?.bindAddress.address, '0.0.0.0');
      expect(controller.state.settings?.theme, ThemePreference.system);
      expect(controller.state.outcome, isA<SettingsIdle>());
    });

    test('shows what was stored', () async {
      await controller.saveBindAddress('10.8.0.3');

      final second = SettingsController(app);
      await second.load();

      expect(second.state.settings?.bindAddress.address, '10.8.0.3');
      second.dispose();
    });

    test(
      'a damaged file is surfaced, and never read as the defaults',
      () async {
        final file = await settingsFile();
        await file.parent.create(recursive: true);
        await file.writeAsString('{"version": "1.0", "netw');

        await controller.load();

        expect(controller.state.settings, isNull);
        expect(controller.state.outcome, isA<SettingsFailed>());
        expect(
          (controller.state.outcome as SettingsFailed).message,
          contains(file.path),
        );
      },
    );
  });

  group('saveBindAddress', () {
    test('stores a literal, and says where the next code is offered', () async {
      await controller.saveBindAddress('10.8.0.3');

      expect(controller.state.settings?.bindAddress.address, '10.8.0.3');
      final outcome = controller.state.outcome;
      expect(outcome, isA<SettingsSaved>());
      expect((outcome as SettingsSaved).message, contains('10.8.0.3'));
      expect((await settingsFile()).existsSync(), isTrue);
    });

    test('stores a wildcard, and says the code still has to guess', () async {
      await controller.saveBindAddress('0.0.0.0');

      final outcome = controller.state.outcome;
      expect(outcome, isA<SettingsSaved>());
      expect((outcome as SettingsSaved).message, contains('best guess'));
    });

    test('accepts an IPv6 literal, bracketed or bare', () async {
      await controller.saveBindAddress('[fd00::5]');

      expect(controller.state.settings?.bindAddress.address, 'fd00::5');
    });

    test('refuses a hostname, in parseBindAddress\'s own words', () async {
      await controller.load();

      await controller.saveBindAddress('my-laptop.local');

      final outcome = controller.state.outcome;
      expect(outcome, isA<SettingsFailed>());
      expect(
        (outcome as SettingsFailed).message,
        contains('is not an IP address'),
      );
      // Refused before anything was written: the shown value is untouched
      // and no file was created.
      expect(controller.state.settings?.bindAddress.address, '0.0.0.0');
      expect((await settingsFile()).existsSync(), isFalse);
    });

    test('refuses text that is not an address at all', () async {
      await controller.saveBindAddress('not an address');

      expect(controller.state.outcome, isA<SettingsFailed>());
      expect((await settingsFile()).existsSync(), isFalse);
    });
  });

  group('saveTheme', () {
    test('stores the theme, and the app draws in it at once', () async {
      await controller.saveTheme(ThemePreference.dark);

      expect(controller.state.settings?.theme, ThemePreference.dark);
      expect(controller.state.outcome, isA<SettingsIdle>());
      expect(app.state.theme, ThemePreference.dark);

      final second = SettingsController(app);
      await second.load();
      expect(second.state.settings?.theme, ThemePreference.dark);
      second.dispose();
    });

    test('keeps the stored bind address, and a later address keeps the '
        'theme', () async {
      await controller.saveBindAddress('10.8.0.3');
      await controller.saveTheme(ThemePreference.light);
      await controller.saveBindAddress('10.8.0.4');

      final second = SettingsController(app);
      await second.load();
      expect(second.state.settings?.bindAddress.address, '10.8.0.4');
      expect(second.state.settings?.theme, ThemePreference.light);
      second.dispose();
    });

    test(
      'a damaged file is not overwritten, and the app keeps its theme',
      () async {
        final file = await settingsFile();
        await file.parent.create(recursive: true);
        await file.writeAsString('{"version": "1.0", "netw');

        await controller.saveTheme(ThemePreference.dark);

        final outcome = controller.state.outcome;
        expect(outcome, isA<SettingsFailed>());
        expect((outcome as SettingsFailed).message, contains(file.path));
        expect(app.state.theme, ThemePreference.system);
        expect(await file.readAsString(), '{"version": "1.0", "netw');
      },
    );
  });
}
