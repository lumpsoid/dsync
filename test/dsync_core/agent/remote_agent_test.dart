import 'dart:async';
import 'dart:convert';

import 'package:dsync/dsync_core/agent/agent.dart';
import 'package:dsync/dsync_core/agent/agent_server.dart';
import 'package:dsync/dsync_core/agent/remote_agent.dart';
import 'package:dsync/dsync_core/models/archive.dart';
import 'package:dsync/dsync_core/models/file_metadata.dart';
import 'package:dsync/dsync_core/models/scan_entry.dart';
import 'package:dsync/dsync_core/protocol/control_message.dart';
import 'package:dsync/dsync_core/protocol/in_memory_channel.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late _FakeAgent backing;
  late RemoteAgent remote;

  setUp(() async {
    final (clientChannel, serverChannel) = InMemoryChannel.pair();
    backing = _FakeAgent();
    unawaited(AgentServer().serve(serverChannel, backing));
    remote = RemoteAgent(clientChannel);
    await remote.hello();
  });

  group('lock / unlock', () {
    test('dispatch to the backing agent', () async {
      await remote.lock();
      expect(backing.locked, isTrue);

      await remote.unlock();
      expect(backing.locked, isFalse);
    });

    test('a remote failure surfaces as AgentOperationException', () async {
      backing.lockError = Exception('locked elsewhere');

      await expectLater(remote.lock(), throwsA(isA<AgentOperationException>()));
    });
  });

  group('scan', () {
    test('returns the entries the backing agent reports', () async {
      backing.scanResult = [
        const ScanEntry(
          path: 'a.txt',
          status: ScanStatus.created,
          size: 1,
          mtime: 1,
          mode: 420,
          hash: 'h',
        ),
      ];

      final entries = await remote.scan();

      expect(entries.single.path, 'a.txt');
      expect(entries.single.status, ScanStatus.created);
      expect(entries.single.hash, 'h');
    });
  });

  group('readFile', () {
    test('streams the bytes the backing agent holds', () async {
      backing.fileContents['a.txt'] = utf8.encode('hello');

      final chunks = await remote.readFile('a.txt').toList();

      expect(utf8.decode(chunks.expand((c) => c).toList()), 'hello');
    });

    test('a missing file throws AgentOperationException', () async {
      await expectLater(
        remote.readFile('missing.txt').toList(),
        throwsA(isA<AgentOperationException>()),
      );
    });
  });

  group('writeFile', () {
    test('writes through and returns the resulting metadata', () async {
      final metadata = await remote.writeFile(
        'a.txt',
        Stream.value(utf8.encode('hello')),
        mtime: 123,
        mode: 420,
      );

      expect(utf8.decode(backing.fileContents['a.txt']!), 'hello');
      expect(metadata.size, 5);
      expect(metadata.mtime, 123);
      expect(metadata.mode, 420);
    });
  });

  group('delete / removeEmptyDirs', () {
    test('dispatch with the path', () async {
      backing.fileContents['a.txt'] = utf8.encode('x');

      await remote.delete('a.txt');
      expect(backing.fileContents.containsKey('a.txt'), isFalse);

      await remote.removeEmptyDirs('a.txt');
      expect(backing.removedEmptyDirsFor, 'a.txt');
    });
  });

  group('archive commits', () {
    test('dispatch upsert and delete', () async {
      const entry = ArchiveEntry(
        path: 'a.txt',
        size: 1,
        mtime: 1,
        mode: 420,
        hash: 'h',
      );

      await remote.archiveCommitUpsert(entry);
      expect(backing.archive['a.txt']?.hash, 'h');

      await remote.archiveCommitDelete('a.txt');
      expect(backing.archive.containsKey('a.txt'), isFalse);
    });
  });
}

/// A minimal in-memory [Agent] fake — just enough to be driven through
/// [RemoteAgent]'s wire protocol without a real filesystem or archive.
class _FakeAgent implements Agent {
  bool locked = false;
  List<ScanEntry> scanResult = [];
  final Map<String, List<int>> fileContents = {};
  final Map<String, ArchiveEntry> archive = {};
  String? removedEmptyDirsFor;
  Object? lockError;

  @override
  Future<void> hello() async {}

  @override
  Future<void> lock() async {
    if (lockError != null) throw lockError!;
    locked = true;
  }

  @override
  Future<void> unlock() async {
    locked = false;
  }

  @override
  Future<List<ScanEntry>> scan() async => scanResult;

  @override
  Stream<List<int>> readFile(String path) {
    final bytes = fileContents[path];
    if (bytes == null) {
      return Stream<List<int>>.error(Exception('not found: $path'));
    }
    return Stream.value(bytes);
  }

  @override
  Future<FileMetadata> writeFile(
    String path,
    Stream<List<int>> data, {
    required int mtime,
    required int mode,
  }) async {
    final bytes = <int>[];
    await for (final chunk in data) {
      bytes.addAll(chunk);
    }
    fileContents[path] = bytes;
    return FileMetadata(size: bytes.length, mtime: mtime, mode: mode);
  }

  @override
  Future<void> delete(String path) async {
    fileContents.remove(path);
  }

  @override
  Future<void> removeEmptyDirs(String path) async {
    removedEmptyDirsFor = path;
  }

  @override
  Future<void> archiveCommitUpsert(ArchiveEntry entry) async {
    archive[entry.path] = entry;
  }

  @override
  Future<void> archiveCommitDelete(String path) async {
    archive.remove(path);
  }
}
