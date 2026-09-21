import 'dart:io';

import 'package:dsync/app/app_settings.dart';
import 'package:dsync/app/app_settings_store.dart';
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

  group('load', () {
    test(
      'a missing file is the first-run defaults, and creates nothing',
      () async {
        expect(storeFile().existsSync(), isFalse);

        final settings = await store().load();

        expect(settings.bindAddress.address, '0.0.0.0');
        expect(storeFile().existsSync(), isFalse);
      },
    );

    test('reads back what was saved', () async {
      await store().save(AppSettings(bindAddress: InternetAddress('10.8.0.3')));

      expect((await store().load()).bindAddress.address, '10.8.0.3');
    });

    test('an IPv6 literal survives the round trip', () async {
      await store().save(AppSettings(bindAddress: InternetAddress('fd00::5')));

      expect((await store().load()).bindAddress.address, 'fd00::5');
    });

    test('a later save replaces the whole document', () async {
      await store().save(AppSettings(bindAddress: InternetAddress('10.8.0.3')));
      await store().save(AppSettings(bindAddress: InternetAddress('0.0.0.0')));

      expect((await store().load()).bindAddress.address, '0.0.0.0');
    });

    test(
      'reads are fresh: a write through one store is seen by the next',
      () async {
        final reader = store();
        expect((await reader.load()).bindAddress.address, '0.0.0.0');

        await store().save(
          AppSettings(bindAddress: InternetAddress('10.8.0.3')),
        );

        expect((await reader.load()).bindAddress.address, '10.8.0.3');
      },
    );

    test('malformed JSON is corruption, not the defaults', () async {
      await storeFile().writeAsString('{"schemaVersion": 1, "netw');

      await expectLater(
        store().load(),
        throwsA(isA<AppSettingsStoreCorruptException>()),
      );
    });

    test('another schema version is corruption', () async {
      await storeFile().writeAsString(
        '{"schemaVersion": 2, "network": {"bindAddress": "0.0.0.0"}}',
      );

      await expectLater(
        store().load(),
        throwsA(isA<AppSettingsStoreCorruptException>()),
      );
    });

    test('a missing network section is corruption', () async {
      await storeFile().writeAsString('{"schemaVersion": 1}');

      await expectLater(
        store().load(),
        throwsA(isA<AppSettingsStoreCorruptException>()),
      );
    });

    test('a stored hostname is corruption, by the same rule the page '
        'refuses one with', () async {
      await storeFile().writeAsString(
        '{"schemaVersion": 1, "network": {"bindAddress": "localhost"}}',
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

      await nested.save(AppSettings(bindAddress: InternetAddress('0.0.0.0')));

      expect((await nested.load()).bindAddress.address, '0.0.0.0');
    });

    test('leaves no scratch file behind', () async {
      await store().save(AppSettings(bindAddress: InternetAddress('0.0.0.0')));

      expect(tempDir.listSync().map((e) => e.path.split('/').last), [
        'settings.json',
      ]);
    });
  });
}
