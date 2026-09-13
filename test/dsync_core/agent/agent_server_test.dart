import 'dart:async';
import 'dart:convert';

import 'package:dsync/dsync_core/agent/agent.dart';
import 'package:dsync/dsync_core/agent/agent_server.dart';
import 'package:dsync/dsync_core/models/archive.dart';
import 'package:dsync/dsync_core/models/file_metadata.dart';
import 'package:dsync/dsync_core/models/frame.dart';
import 'package:dsync/dsync_core/models/rule_set.dart';
import 'package:dsync/dsync_core/models/scan_entry.dart';
import 'package:dsync/dsync_core/models/scan_result.dart';
import 'package:dsync/dsync_core/protocol/channel.dart';
import 'package:dsync/dsync_core/protocol/control_message.dart';
import 'package:dsync/dsync_core/protocol/frame_codec.dart';
import 'package:dsync/dsync_core/protocol/in_memory_channel.dart';
import 'package:dsync/dsync_core/protocol/version_handshake.dart';
import 'package:test/test.dart';

void main() {
  late _FakeAgent agent;
  late Channel client;
  late StreamIterator<Frame> clientFrames;

  setUp(() async {
    final (a, b) = InMemoryChannel.pair();
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

      final result = await call('scan', {
        'rules': ruleSetToJson(RuleSet()),
      }) as AgentSuccess;

      final entries = (result.data['entries'] as List)
          .cast<Map<String, dynamic>>();
      expect(entries.single['path'], 'a.txt');
      expect(entries.single['status'], 'created');
    });

    test("hands the request's rules to the agent", () async {
      agent.scanResult = [];

      await call('scan', {
        'rules': ruleSetToJson(RuleSet(ignore: ['*.tmp'])),
      });

      // The rules come from the initiator's profile (SPEC §9), so the server
      // must pass through what it was sent rather than scanning by its own.
      expect(agent.lastScanRules?.ignorePatterns, ['*.tmp']);
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

    test('a write that fails before reading the bytes still serves the next '
        'request', () async {
      agent.writeError = Exception('permission denied');

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
      expect(AgentResult.fromFrame(clientFrames.current), isA<AgentFailure>());

      // The peer had already committed to sending the whole transfer. If
      // those frames were left queued the serve loop would read file bytes
      // where it expects a request — and SPEC §7.6 keeps the run going, so
      // there is always a next request.
      expect(await call('lock'), isA<AgentSuccess>());
    });
  });

  group('malformed frames', () {
    test(
      'a frame that is not a request fails without ending the session',
      () async {
        await client.send(
          FrameCodec().encode(
            const Frame(type: FrameType.control, payload: [0x7b, 0x7b]),
          ),
        );

        await clientFrames.moveNext();
        expect(
          AgentResult.fromFrame(clientFrames.current),
          isA<AgentFailure>(),
        );

        expect(await call('lock'), isA<AgentSuccess>());
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

  group('compact', () {
    test('dispatches to the agent', () async {
      expect(await call('compact'), isA<AgentSuccess>());
      expect(agent.compacted, isTrue);
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

/// A minimal in-memory [Agent] fake — just enough to drive [AgentServer]'s
/// dispatch logic without a real filesystem or archive.
class _FakeAgent implements Agent {
  bool locked = false;
  List<ScanEntry> scanResult = [];
  RuleSet? lastScanRules;
  final Map<String, List<int>> fileContents = {};
  final Map<String, ArchiveEntry> archive = {};
  String? removedEmptyDirsFor;
  Object? lockError;
  Object? writeError;

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
  Future<ScanResult> scan(RuleSet rules) async {
    lastScanRules = rules;
    return ScanResult(entries: scanResult);
  }

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
    // Thrown before `data` is touched, like a parent directory that cannot
    // be created.
    if (writeError != null) throw writeError!;
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

  bool compacted = false;

  @override
  Future<void> compact() async {
    compacted = true;
  }

  @override
  Future<void> disconnect() async {}
}
