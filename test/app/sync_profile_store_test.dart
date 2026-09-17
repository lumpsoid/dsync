import 'dart:io';

import 'package:dsync/app/sync_profile.dart';
import 'package:dsync/app/sync_profile_store.dart';
import 'package:test/test.dart';

/// Covers `SyncProfileStore` against real temporary directories (SPEC §14),
/// the same house pattern `paired_device_store_test.dart` uses — the store
/// deliberately mirrors it: fresh reads, one JSON document rewritten
/// atomically, absent is empty and damaged is an exception.
void main() {
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('sync_profile_store_test');
  });

  tearDown(() async {
    await tempDir.delete(recursive: true);
  });

  File storeFile() => File('${tempDir.path}/sync-profiles.json');

  SyncProfileStore store() => SyncProfileStore(storeFile());

  SyncProfile profile(String id, {String name = 'notes'}) => SyncProfile(
    id: id,
    name: name,
    localRootPath: '/on-device/notes',
    peerDeviceId: 'peer-$id',
    remoteRootPath: '~/notes',
    jobs: 4,
  );

  void expectSameProfile(SyncProfile? actual, SyncProfile expected) {
    expect(actual, isNotNull);
    expect(actual!.id, expected.id);
    expect(actual.name, expected.name);
    expect(actual.localRootPath, expected.localRootPath);
    expect(actual.peerDeviceId, expected.peerDeviceId);
    expect(actual.remoteRootPath, expected.remoteRootPath);
    expect(actual.jobs, expected.jobs);
  }

  group('load', () {
    test(
      'a missing file is the empty first-run case, and creates nothing',
      () async {
        expect(storeFile().existsSync(), isFalse);
        expect(await store().load(), isEmpty);
      },
    );

    test('reads back what was saved, in saved order', () async {
      await store().save(profile('a', name: 'alpha'));
      await store().save(profile('b', name: 'beta'));

      final loaded = await store().load();

      expect(loaded.map((p) => p.name), ['alpha', 'beta']);
      expectSameProfile(loaded.first, profile('a', name: 'alpha'));
    });

    test('a fresh store over the same file sees the same list', () async {
      // A second process (or a second controller) reads the same file —
      // nothing is held in memory across stores.
      await store().save(profile('a'));

      expectSameProfile(
        await SyncProfileStore(storeFile()).byId('a'),
        profile('a'),
      );
    });

    test('damaged bytes are corruption, never an empty list', () async {
      for (final raw in [
        '{"schemaVersion": 1, "profiles":',
        'not json',
        '{"schemaVersion": 2, "profiles": []}',
        '{"schemaVersion": 1, "devices": []}',
        '[]',
      ]) {
        storeFile().parent.createSync(recursive: true);
        storeFile().writeAsStringSync(raw);

        await expectLater(
          store().load(),
          throwsA(isA<SyncProfileStoreCorruptException>()),
          reason: raw,
        );
        storeFile().deleteSync();
      }
    });
  });

  group('save', () {
    test('upserts by id: a second save over the same id replaces it', () async {
      await store().save(profile('a'));

      await store().save(profile('a', name: 'renamed'));

      final loaded = await store().load();
      expect(loaded, hasLength(1));
      expect(loaded.single.name, 'renamed');
    });

    test('keeps the entries it replaces nothing of', () async {
      await store().save(profile('a'));
      await store().save(profile('b'));

      await store().save(profile('a', name: 'a-edited'));

      expect((await store().load()).map((p) => p.id), ['a', 'b']);
    });
  });

  group('delete', () {
    test('removes exactly the named profile', () async {
      await store().save(profile('a'));
      await store().save(profile('b'));

      await store().delete('a');

      expect((await store().load()).map((p) => p.id), ['b']);
    });

    test('a missing id is a rendered refusal, not silence', () async {
      await expectLater(
        store().delete('nope'),
        throwsA(isA<SyncProfileNotFoundException>()),
      );
    });
  });

  test('the write is atomic: a scratch file never survives a save', () async {
    // Positive control on the rename-over pattern: after any number of
    // saves the only file in the directory is the store itself.
    await store().save(profile('a'));
    await store().save(profile('b', name: 'second'));

    expect(tempDir.listSync().map((e) => e.path), [storeFile().path]);
  });

  test('a profile round-trips through the document the store wrote', () async {
    await store().save(profile('a', name: 'weekly'));

    // The document is this store's shape and only its shape: entries that
    // decode back to what went in, under the one version the store writes.
    expectSameProfile(
      await SyncProfileStore(storeFile()).byId('a'),
      profile('a', name: 'weekly'),
    );
  });
}
