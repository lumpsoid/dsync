import 'package:dsync/dsync_core/models/replica_info.dart';
import 'package:dsync/dsync_core/models/replica_root.dart';
import 'package:test/test.dart';

/// SPEC §4.5's rule over plain values: a missing root is created on its
/// replica's first sync and refused once that replica has an archive.
void main() {
  group('mustCreateRoot', () {
    test('a present root needs nothing, archive or not', () {
      expect(
        const ReplicaInfo(root: RootPresent()).mustCreateRoot(onA: true),
        isFalse,
      );
      expect(
        ReplicaInfo(
          lastCommitTime: DateTime.utc(2026, 9, 1),
          root: const RootPresent(),
        ).mustCreateRoot(onA: true),
        isFalse,
      );
    });

    test('a missing root with no archive is created: its first sync', () {
      const info = ReplicaInfo(
        root: RootMissing(rootPath: '/phone/synth', archivedFiles: 0),
      );

      expect(info.mustCreateRoot(onA: false), isTrue);
    });

    test('a missing root with an archive is refused, naming the side, the '
        'path and what the last sync saw there', () {
      final info = ReplicaInfo(
        lastCommitTime: DateTime.utc(2026, 9, 1),
        root: const RootMissing(rootPath: '/media/sd/notes', archivedFiles: 42),
      );

      expect(
        () => info.mustCreateRoot(onA: false),
        throwsA(
          isA<MissingReplicaRootException>()
              .having((e) => e.onA, 'onA', isFalse)
              .having((e) => e.rootPath, 'rootPath', '/media/sd/notes')
              .having((e) => e.archivedFiles, 'archivedFiles', 42),
        ),
      );
    });
  });

  group('MissingReplicaRootException wording', () {
    const missing = MissingReplicaRootException(
      onA: false,
      rootPath: '/media/sd/notes',
      archivedFiles: 42,
    );

    test('names the device it is on', () {
      expect(
        missing.describeOn('phone'),
        'The folder /media/sd/notes on phone is missing. If it is on a drive '
        'that is not mounted, reconnect it; the last sync saw 42 files there.',
      );
    });

    test('is plain text, not a Dart exception string', () {
      expect(
        missing.toString(),
        'The folder /media/sd/notes is missing. If it is on a drive that is '
        'not mounted, reconnect it; the last sync saw 42 files there.',
      );
    });
  });
}
