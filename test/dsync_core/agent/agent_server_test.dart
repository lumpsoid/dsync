import 'dart:async';
import 'dart:convert';

import 'package:dsync/dsync_core/agent/agent.dart';
import 'package:dsync/dsync_core/agent/agent_server.dart';
import 'package:dsync/dsync_core/models/archive.dart';
import 'package:dsync/dsync_core/models/file_metadata.dart';
import 'package:dsync/dsync_core/models/frame.dart';
import 'package:dsync/dsync_core/models/scan_entry.dart';
import 'package:dsync/dsync_core/protocol/channel.dart';
import 'package:dsync/dsync_core/protocol/control_message.dart';
import 'package:dsync/dsync_core/protocol/frame_codec.dart';
import 'package:dsync/dsync_core/protocol/version_handshake.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late _FakeAgent agent;
  late Channel client;
  late StreamIterator<Frame> clientFrames;

  setUp(() async {
    final (a, b) = _pairedChannels();
    client = a;
    agent = _FakeAgent();
    clientFrames = StreamIterator(FrameCodec().decode(client.input));

    unawaited(AgentServer().serve(b, agent));
    await performVersionHandshake(client, clientFrames);
  });

  Future<AgentResult> call(
    String op, [
    Map<String, dynamic> params = const {},
  ]) async {
    await client.send(FrameCodec().encode(AgentRequest(op, params).toFrame()));
    await clientFrames.moveNext();
    return AgentResult.fromFrame(clientFrames.current);
  }

  group('lock / unlock', () {
    test('dispatch to the agent and reply success', () async {
      expect(await call('lock'), isA<AgentSuccess>());
      expect(agent.locked, isTrue);

      expect(await call('unlock'), isA<AgentSuccess>());
      expect(agent.locked, isFalse);
    });
  });

  group('scan', () {
    test('replies with the serialized entries', () async {
      agent.scanResult = [
        const ScanEntry(
          path: 'a.txt',
          status: ScanStatus.created,
          size: 1,
          mtime: 1,
          mode: 420,
          hash: 'h',
        ),
      ];

      final result = await call('scan') as AgentSuccess;

      final entries = (result.data['entries'] as List)
          .cast<Map<String, dynamic>>();
      expect(entries.single['path'], 'a.txt');
      expect(entries.single['status'], 'created');
    });
  });

  group('readFile', () {
    test("streams the file's bytes as fileBytes frames, terminated", () async {
      agent.fileContents['a.txt'] = utf8.encode('hello');

      await client.send(
        FrameCodec().encode(
          const AgentRequest('readFile', {'path': 'a.txt'}).toFrame(),
        ),
      );

      final chunks = await readByteStream(clientFrames).toList();
      expect(utf8.decode(chunks.expand((c) => c).toList()), 'hello');
    });

    test(
      'a missing file replies with a failure instead of streaming',
      () async {
        await client.send(
          FrameCodec().encode(
            const AgentRequest('readFile', {'path': 'missing.txt'}).toFrame(),
          ),
        );

        await expectLater(
          readByteStream(clientFrames).toList(),
          throwsA(isA<AgentOperationException>()),
        );
      },
    );
  });

  group('writeFile', () {
    test(
      'writes the streamed bytes and replies with the resulting metadata',
      () async {
        await client.send(
          FrameCodec().encode(
            const AgentRequest('writeFile', {
              'path': 'a.txt',
              'mtime': 123,
              'mode': 420,
            }).toFrame(),
          ),
        );
        await sendByteStream(client, Stream.value(utf8.encode('hello')));

        await clientFrames.moveNext();
        final result =
            AgentResult.fromFrame(clientFrames.current) as AgentSuccess;

        expect(utf8.decode(agent.fileContents['a.txt']!), 'hello');
        expect(result.data['metadata'], {'size': 5, 'mtime': 123, 'mode': 420});
      },
    );
  });

  group('delete / removeEmptyDirs', () {
    test('dispatch with the path', () async {
      agent.fileContents['a.txt'] = utf8.encode('x');

      expect(await call('delete', {'path': 'a.txt'}), isA<AgentSuccess>());
      expect(agent.fileContents.containsKey('a.txt'), isFalse);

      expect(
        await call('removeEmptyDirs', {'path': 'a.txt'}),
        isA<AgentSuccess>(),
      );
      expect(agent.removedEmptyDirsFor, 'a.txt');
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

      expect(
        await call('archiveCommitUpsert', {'entry': archiveEntryToJson(entry)}),
        isA<AgentSuccess>(),
      );
      expect(agent.archive['a.txt']?.hash, 'h');

      expect(
        await call('archiveCommitDelete', {'path': 'a.txt'}),
        isA<AgentSuccess>(),
      );
      expect(agent.archive.containsKey('a.txt'), isFalse);
    });
  });

  group('errors', () {
    test('an unknown op replies with a failure', () async {
      expect(await call('bogus'), isA<AgentFailure>());
    });

    test('an exception from the agent is reported as a failure', () async {
      agent.lockError = Exception('locked elsewhere');

      final result = await call('lock') as AgentFailure;

      expect(result.error, contains('locked elsewhere'));
    });
  });
}

(Channel, Channel) _pairedChannels() {
  final aToB = StreamController<List<int>>();
  final bToA = StreamController<List<int>>();
  final a = _FakeChannel(outbox: aToB, input: bToA.stream);
  final b = _FakeChannel(outbox: bToA, input: aToB.stream);
  return (a, b);
}

/// A minimal [Channel] wiring two in-memory byte streams — just enough to
/// drive the protocol in isolation. The real shared in-memory `Channel`
/// (SPEC §14) is a separate task; this one stays test-local.
class _FakeChannel implements Channel {
  final StreamController<List<int>> outbox;
  @override
  final Stream<List<int>> input;

  _FakeChannel({required this.outbox, required this.input});

  @override
  Future<void> send(List<int> bytes) async {
    outbox.add(bytes);
  }

  @override
  Future<void> close() async {
    await outbox.close();
  }
}

/// A minimal in-memory [Agent] fake — just enough to drive [AgentServer]'s
/// dispatch logic without a real filesystem or archive.
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
