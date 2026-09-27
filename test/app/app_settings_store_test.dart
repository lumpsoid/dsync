import 'dart:io';

import 'package:dsync/app/app_settings.dart';
import 'package:dsync/app/app_settings_store.dart';
import 'package:dsync/app/atomic_write.dart';
import 'package:dsync/app/peer_port.dart';
import 'package:dsync/app/theme_preference.dart';
import 'package:dsync/app/warn_size.dart';
import 'package:test/test.dart';

/// Covers `AppSettingsStore` against real temporary directories (SPEC §14),
/// the same house pattern `sync_profile_store_test.dart` uses — the store
/// deliberately mirrors it: fresh reads, one versioned JSON document
/// rewritten atomically, absent is the defaults and damaged is an
/// exception.
void main() {
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('app_settings_store_test');
  });

  tearDown(() async {
    await tempDir.delete(recursive: true);
  });

  File storeFile() => File('${tempDir.path}/settings.json');

  AppSettingsStore store() => AppSettingsStore(storeFile());

  AppSettings at(String address) =>
      AppSettings.defaults.withBindAddress(InternetAddress(address));

  group('load', () {
    test(
      'a missing file is the first-run defaults, and creates nothing',
      () async {
        expect(storeFile().existsSync(), isFalse);

        final settings = await store().load();

        expect(settings.bindAddress.address, '0.0.0.0');
        expect(settings.theme, ThemePreference.system);
        expect(settings.keepScreenAwake, isTrue);
        expect(settings.peerPort, PeerPort(defaultPeerPort));
        expect(settings.warnSize, const WarnSizeOff());
        expect(storeFile().existsSync(), isFalse);
      },
    );

    test('reads back what was saved, written as version 1.4', () async {
      await store().save(at('10.8.0.3'));

      expect(storeFile().readAsStringSync(), contains('"version":"1.4"'));
      expect((await store().load()).bindAddress.address, '10.8.0.3');
    });

    test('the theme survives the round trip beside the address', () async {
      await store().save(at('10.8.0.3').withTheme(ThemePreference.dark));

      final settings = await store().load();
      expect(settings.theme, ThemePreference.dark);
      expect(settings.bindAddress.address, '10.8.0.3');
    });

    test('keeping the screen awake off survives the round trip beside the '
        'others', () async {
      await store().save(
        at('10.8.0.3')
            .withTheme(ThemePreference.dark)
            .withKeepScreenAwake(false),
      );

      final settings = await store().load();
      expect(settings.keepScreenAwake, isFalse);
      expect(settings.theme, ThemePreference.dark);
      expect(settings.bindAddress.address, '10.8.0.3');
    });

    test('the peer port survives the round trip beside the others', () async {
      await store().save(
        at('10.8.0.3').withPeerPort(PeerPort(9000)).withKeepScreenAwake(false),
      );

      expect(storeFile().readAsStringSync(), contains('"peerPort":9000'));
      final settings = await store().load();
      expect(settings.peerPort, PeerPort(9000));
      expect(settings.keepScreenAwake, isFalse);
      expect(settings.bindAddress.address, '10.8.0.3');
    });

    test('the warn size survives the round trip beside the others', () async {
      await store().save(
        at('10.8.0.3')
            .withWarnSize(WarnSizeAbove(500000000))
            .withPeerPort(PeerPort(9000)),
      );

      expect(
        storeFile().readAsStringSync(),
        contains('"warnSizeBytes":500000000'),
      );
      final settings = await store().load();
      expect(settings.warnSize, WarnSizeAbove(500000000));
      expect(settings.peerPort, PeerPort(9000));
      expect(settings.bindAddress.address, '10.8.0.3');

      await store().save(settings.withWarnSize(const WarnSizeOff()));
      expect((await store().load()).warnSize, const WarnSizeOff());
    });

    test('a 1.3 document, which has no sync section, warns about no '
        'size', () async {
      await storeFile().writeAsString(
        '{"version": "1.3", "network": '
        '{"bindAddress": "10.8.0.3", "peerPort": 9000}}',
      );

      final settings = await store().load();
      expect(settings.warnSize, const WarnSizeOff());
      expect(settings.peerPort, PeerPort(9000));
    });

    for (final sync in [
      '{"warnSizeBytes": 0}',
      '{"warnSizeBytes": -5}',
      '{"warnSizeBytes": "500"}',
      '{"warnSizeBytes": 1.5}',
      '{}',
      '[]',
    ]) {
      test('a sync section of $sync is corruption', () async {
        await storeFile().writeAsString(
          '{"version": "1.4", "network": {"bindAddress": "0.0.0.0"}, '
          '"sync": $sync}',
        );

        await expectLater(
          store().load(),
          throwsA(isA<AppSettingsStoreCorruptException>()),
        );
      });
    }

    test('a 1.2 document, which has no peer port, serves on the default '
        'one', () async {
      await storeFile().writeAsString(
        '{"version": "1.2", "network": {"bindAddress": "10.8.0.3"}, '
        '"power": {"keepScreenAwake": false}}',
      );

      final settings = await store().load();
      expect(settings.peerPort, PeerPort(defaultPeerPort));
      expect(settings.keepScreenAwake, isFalse);
    });

    for (final port in ['0', '65536', '-1', '"9000"', '9000.5', 'null']) {
      test('a peer port of $port is corruption', () async {
        await storeFile().writeAsString(
          '{"version": "1.3", "network": '
          '{"bindAddress": "0.0.0.0", "peerPort": $port}}',
        );

        await expectLater(
          store().load(),
          throwsA(isA<AppSettingsStoreCorruptException>()),
        );
      });
    }

    test('a 1.1 document, which has no power section, keeps the screen '
        'awake', () async {
      await storeFile().writeAsString(
        '{"version": "1.1", "network": {"bindAddress": "10.8.0.3"}, '
        '"appearance": {"theme": "dark"}}',
      );

      final settings = await store().load();
      expect(settings.keepScreenAwake, isTrue);
      expect(settings.theme, ThemePreference.dark);
    });

    test('a keep-awake switch that is not a boolean is corruption', () async {
      await storeFile().writeAsString(
        '{"version": "1.2", "network": {"bindAddress": "0.0.0.0"}, '
        '"power": {"keepScreenAwake": "yes"}}',
      );

      await expectLater(
        store().load(),
        throwsA(isA<AppSettingsStoreCorruptException>()),
      );
    });

    test('a power section that is not an object is corruption', () async {
      await storeFile().writeAsString(
        '{"version": "1.2", "network": {"bindAddress": "0.0.0.0"}, '
        '"power": true}',
      );

      await expectLater(
        store().load(),
        throwsA(isA<AppSettingsStoreCorruptException>()),
      );
    });

    test('a 1.0 document, which has no theme, reads as System', () async {
      await storeFile().writeAsString(
        '{"version": "1.0", "network": {"bindAddress": "10.8.0.3"}}',
      );

      final settings = await store().load();
      expect(settings.theme, ThemePreference.system);
      expect(settings.keepScreenAwake, isTrue);
      expect(settings.bindAddress.address, '10.8.0.3');
    });

    test('an unknown theme is corruption, not System', () async {
      await storeFile().writeAsString(
        '{"version": "1.1", "network": {"bindAddress": "0.0.0.0"}, '
        '"appearance": {"theme": "sepia"}}',
      );

      await expectLater(
        store().load(),
        throwsA(isA<AppSettingsStoreCorruptException>()),
      );
    });

    test('an appearance section that is not an object is corruption', () async {
      await storeFile().writeAsString(
        '{"version": "1.1", "network": {"bindAddress": "0.0.0.0"}, '
        '"appearance": "dark"}',
      );

      await expectLater(
        store().load(),
        throwsA(isA<AppSettingsStoreCorruptException>()),
      );
    });

    test('an IPv6 literal survives the round trip', () async {
      await store().save(at('fd00::5'));

      expect((await store().load()).bindAddress.address, 'fd00::5');
    });

    test('a later save replaces the whole document', () async {
      await store().save(at('10.8.0.3'));
      await store().save(at('0.0.0.0'));

      expect((await store().load()).bindAddress.address, '0.0.0.0');
    });

    test(
      'reads are fresh: a write through one store is seen by the next',
      () async {
        final reader = store();
        expect((await reader.load()).bindAddress.address, '0.0.0.0');

        await store().save(at('10.8.0.3'));

        expect((await reader.load()).bindAddress.address, '10.8.0.3');
      },
    );

    test('malformed JSON is corruption, not the defaults', () async {
      await storeFile().writeAsString('{"version": "1.0", "netw');

      await expectLater(
        store().load(),
        throwsA(isA<AppSettingsStoreCorruptException>()),
      );
    });

    test('a later major is refused, naming both versions', () async {
      await storeFile().writeAsString(
        '{"version": "2.0", "network": {"bindAddress": "0.0.0.0"}}',
      );

      await expectLater(
        store().load(),
        throwsA(
          isA<AppSettingsStoreForeignVersionException>().having(
            (e) => e.toString(),
            'message',
            allOf(
              contains(storeFile().path),
              contains('format 2.0'),
              contains('(format 1.4)'),
              contains('reads format 2.x'),
            ),
          ),
        ),
      );
    });

    test('a later minor is read, and its unknown fields ignored', () async {
      await storeFile().writeAsString(
        '{"version": "1.7", "network": {"bindAddress": "10.8.0.3", '
        '"port": 22000}, "theme": "dark"}',
      );

      expect((await store().load()).bindAddress.address, '10.8.0.3');
    });

    test('a version that is not major.minor is corruption', () async {
      await storeFile().writeAsString(
        '{"version": 1, "network": {"bindAddress": "0.0.0.0"}}',
      );

      await expectLater(
        store().load(),
        throwsA(isA<AppSettingsStoreCorruptException>()),
      );
    });

    test('a missing network section is corruption', () async {
      await storeFile().writeAsString('{"version": "1.0"}');

      await expectLater(
        store().load(),
        throwsA(isA<AppSettingsStoreCorruptException>()),
      );
    });

    test('a stored hostname is corruption, by the same rule the page '
        'refuses one with', () async {
      await storeFile().writeAsString(
        '{"version": "1.0", "network": {"bindAddress": "localhost"}}',
      );

      await expectLater(
        store().load(),
        throwsA(isA<AppSettingsStoreCorruptException>()),
      );
    });

    test('the corrupt message names the file and the remedy', () async {
      await storeFile().writeAsString('not json at all');

      expect(
        AppSettingsStoreCorruptException(storeFile().path, 'why').toString(),
        allOf(contains(storeFile().path), contains('Remove it')),
      );
    });
  });

  group('save', () {
    test('creates the state directory when it is not there yet', () async {
      final nested = AppSettingsStore(
        File('${tempDir.path}/deeper/settings.json'),
      );

      await nested.save(at('0.0.0.0'));

      expect((await nested.load()).bindAddress.address, '0.0.0.0');
    });

    test('leaves no scratch file behind', () async {
      await store().save(at('0.0.0.0'));

      expect(tempDir.listSync().map((e) => e.path.split('/').last), [
        'settings.json',
      ]);
    });
  });

  group('writeFileAtomically', () {
    test('replaces a document whole', () async {
      final file = File('${tempDir.path}/doc.json');
      await file.writeAsString('old');

      await writeFileAtomically(file, 'new');

      expect(await file.readAsString(), 'new');
      expect(tempDir.listSync().map((e) => e.path.split('/').last), [
        'doc.json',
      ]);
    });

    test(
      'a failed swap leaves the target as it was and no scratch file',
      () async {
        // A directory cannot be renamed over: the swap is the step that fails.
        final target = Directory('${tempDir.path}/doc.json');
        await File('${target.path}/inside').create(recursive: true);

        await expectLater(
          writeFileAtomically(File(target.path), 'new'),
          throwsA(isA<FileSystemException>()),
        );

        expect(await File('${target.path}/inside').exists(), isTrue);
        expect(tempDir.listSync().map((e) => e.path.split('/').last), [
          'doc.json',
        ]);
      },
    );
  });
}
