import 'dart:io';

import 'package:dsync/app/app_controller.dart';
import 'package:dsync/app/features/settings/settings_controller.dart';
import 'package:dsync/app/features/settings/settings_view_state.dart';
import 'package:dsync/app/mass_delete_guard.dart';
import 'package:dsync/app/peer_port.dart';
import 'package:dsync/app/rust/bindings/bindings.dart' as wire;
import 'package:dsync/app/theme_preference.dart';
import 'package:dsync/app/warn_size.dart';
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

  group('savePeerPort', () {
    test('stores a port, keeping the other settings, and says when it '
        'applies', () async {
      await controller.saveBindAddress('10.8.0.3');
      await controller.saveKeepScreenAwake(false);

      await controller.savePeerPort(' 9000 ');

      expect(controller.state.settings?.peerPort, PeerPort(9000));
      final outcome = controller.state.outcome;
      expect(outcome, isA<SettingsSaved>());
      expect((outcome as SettingsSaved).message, contains('port 9000'));
      final second = SettingsController(app);
      await second.load();
      expect(second.state.settings?.peerPort, PeerPort(9000));
      expect(second.state.settings?.bindAddress.address, '10.8.0.3');
      expect(second.state.settings?.keepScreenAwake, isFalse);
      second.dispose();
    });

    for (final typed in ['0', '65536', 'http', '']) {
      test('refuses "$typed" in PeerPort.parse\'s own words, writing '
          'nothing', () async {
        await controller.load();

        await controller.savePeerPort(typed);

        final outcome = controller.state.outcome;
        expect(outcome, isA<SettingsFailed>());
        expect(
          (outcome as SettingsFailed).message,
          contains('from 1 to 65535'),
        );
        expect(controller.state.settings?.peerPort.value, 28771);
        expect((await settingsFile()).existsSync(), isFalse);
      });
    }
  });

  group('saveWarnSize', () {
    test('stores a size, keeping the other settings, and says when it '
        'applies; empty turns it off', () async {
      await controller.savePeerPort('9000');

      await controller.saveWarnSize(' 1 MiB ');

      expect(controller.state.settings?.warnSize, WarnSizeAbove(1048576));
      final outcome = controller.state.outcome;
      expect(outcome, isA<SettingsSaved>());
      expect((outcome as SettingsSaved).message, contains('than 1 MiB'));
      final second = SettingsController(app);
      await second.load();
      expect(second.state.settings?.warnSize, WarnSizeAbove(1048576));
      expect(second.state.settings?.peerPort, PeerPort(9000));
      second.dispose();

      await controller.saveWarnSize('');
      expect(controller.state.settings?.warnSize, const WarnSizeOff());
      expect(controller.state.outcome, isA<SettingsSaved>());
    });

    for (final typed in ['0', '-1', '5 XB', '1.5']) {
      test('refuses "$typed" in WarnSize.parse\'s own words, writing '
          'nothing', () async {
        await controller.load();

        await controller.saveWarnSize(typed);

        final outcome = controller.state.outcome;
        expect(outcome, isA<SettingsFailed>());
        expect(
          (outcome as SettingsFailed).message,
          contains('e.g. 500 MB or 2 GiB'),
        );
        expect(controller.state.settings?.warnSize, const WarnSizeOff());
        expect((await settingsFile()).existsSync(), isFalse);
      });
    }
  });

  group('the delete guard\'s thresholds', () {
    test('each is stored alone, keeping the other and the other settings, '
        'and the line says the guard still asks', () async {
      await controller.savePeerPort('9000');

      await controller.saveMassDeleteMinFiles(' 3 ');
      expect(
        controller.state.settings?.massDeleteGuard,
        MassDeleteGuard(minFiles: 3, percent: 50),
      );
      await controller.saveMassDeletePercent('20%');
      expect(
        controller.state.settings?.massDeleteGuard,
        MassDeleteGuard(minFiles: 3, percent: 20),
      );
      final outcome = controller.state.outcome;
      expect(outcome, isA<SettingsSaved>());
      expect((outcome as SettingsSaved).message, contains('stops to ask'));

      final second = SettingsController(app);
      await second.load();
      expect(
        second.state.settings?.massDeleteGuard,
        MassDeleteGuard(minFiles: 3, percent: 20),
      );
      expect(second.state.settings?.peerPort, PeerPort(9000));
      second.dispose();
    });

    for (final typed in ['0', '-1', '', 'ten']) {
      test('refuses "$typed" files, writing nothing', () async {
        await controller.load();

        await controller.saveMassDeleteMinFiles(typed);

        final outcome = controller.state.outcome;
        expect(outcome, isA<SettingsFailed>());
        expect((outcome as SettingsFailed).message, contains('at least 1'));
        expect(
          controller.state.settings?.massDeleteGuard,
          MassDeleteGuard.defaults,
        );
        expect((await settingsFile()).existsSync(), isFalse);
      });
    }

    for (final typed in ['0', '101', '', 'half']) {
      test('refuses "$typed" percent, writing nothing', () async {
        await controller.load();

        await controller.saveMassDeletePercent(typed);

        final outcome = controller.state.outcome;
        expect(outcome, isA<SettingsFailed>());
        expect((outcome as SettingsFailed).message, contains('from 1 to 100'));
        expect(
          controller.state.settings?.massDeleteGuard,
          MassDeleteGuard.defaults,
        );
        expect((await settingsFile()).existsSync(), isFalse);
      });
    }
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

  group('saveKeepScreenAwake', () {
    test('stores the switch, keeping the other settings', () async {
      await controller.saveBindAddress('10.8.0.3');
      await controller.saveTheme(ThemePreference.dark);

      await controller.saveKeepScreenAwake(false);

      expect(controller.state.settings?.keepScreenAwake, isFalse);
      expect(controller.state.outcome, isA<SettingsIdle>());
      final second = SettingsController(app);
      await second.load();
      expect(second.state.settings?.keepScreenAwake, isFalse);
      expect(second.state.settings?.theme, ThemePreference.dark);
      expect(second.state.settings?.bindAddress.address, '10.8.0.3');
      second.dispose();
    });

    test('a damaged file is not overwritten', () async {
      final file = await settingsFile();
      await file.parent.create(recursive: true);
      await file.writeAsString('{"version": "1.0", "netw');

      await controller.saveKeepScreenAwake(false);

      final outcome = controller.state.outcome;
      expect(outcome, isA<SettingsFailed>());
      expect((outcome as SettingsFailed).message, contains(file.path));
      expect(await file.readAsString(), '{"version": "1.0", "netw');
    });
  });

  group('readDiagnostics', () {
    test('answers with the core\'s text', () async {
      final text = await controller.readDiagnostics();

      expect(text, startsWith('dsync 0.1.0 on '));
      expect(controller.state.outcome, isA<SettingsIdle>());
    });

    test('a log the core cannot read shows why, and answers nothing', () async {
      final core = FakeHub()
        ..reply<wire.CoreCommandReadDiagnostics>(
          const wire.ReplyResultFailed(message: 'permission denied'),
        );
      final failing = SettingsController(fakeApp(core));
      addTearDown(failing.dispose);

      expect(await failing.readDiagnostics(), isNull);
      final outcome = failing.state.outcome;
      expect(outcome, isA<SettingsFailed>());
      expect(
        (outcome as SettingsFailed).message,
        contains('permission denied'),
      );
    });
  });
}
