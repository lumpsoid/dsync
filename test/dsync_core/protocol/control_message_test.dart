import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dsync/dsync_core/models/archive.dart';
import 'package:dsync/dsync_core/models/file_metadata.dart';
import 'package:dsync/dsync_core/models/frame.dart';
import 'package:dsync/dsync_core/models/replica_info.dart';
import 'package:dsync/dsync_core/models/replica_spec.dart';
import 'package:dsync/dsync_core/models/rule_set.dart';
import 'package:dsync/dsync_core/protocol/channel.dart';
import 'package:dsync/dsync_core/protocol/control_message.dart';
import 'package:dsync/dsync_core/protocol/frame_router.dart';
import 'package:test/test.dart';

void main() {
  group('the peer\'s own span', () {
    test('rides on a success frame and comes back the same', () {
      final stamped = const AgentSuccess({
        'metadata': {'size': 1},
      }).withFarSide(const Duration(milliseconds: 26));

      final decoded = AgentResult.fromFrame(stamped.toFrame(3));

      expect(decoded, isA<AgentSuccess>());
      final data = (decoded as AgentSuccess).data;
      expect(farSideFromJson(data), const Duration(milliseconds: 26));
      // Alongside the operation's own result, not instead of it.
      expect(data['metadata'], {'size': 1});
    });

    test('is absent, not zero, when the peer did not report one', () {
      // What an older build's reply looks like. Zero would read as "the
      // destination is free", which is the conclusion the figure exists to
      // check rather than assume.
      final decoded = AgentResult.fromFrame(
        const AgentSuccess().toFrame(1),
      ) as AgentSuccess;

      expect(farSideFromJson(decoded.data), isNull);
    });
  });

  group('AgentRequest', () {
    test('round-trips an op with params through a frame', () {
      final request = AgentRequest('delete', {'path': 'a.txt'});

      final frame = request.toFrame(7);

      final decoded = AgentRequest.fromFrame(frame);
      expect(decoded.op, 'delete');
      expect(decoded.params, {'path': 'a.txt'});
      // The id is a header field, not part of the payload: it must reach the
      // frame and must not turn up among the params (task 0f7dfc).
      expect(frame.requestId, 7);
    });

    test('round-trips an op with no params', () {
      final decoded = AgentRequest.fromFrame(
        const AgentRequest('lock').toFrame(1),
      );

      expect(decoded.op, 'lock');
      expect(decoded.params, isEmpty);
    });
  });

  group('AgentResult', () {
    test('round-trips a success with data', () {
      final decoded = AgentResult.fromFrame(
        const AgentSuccess({'entries': []}).toFrame(1),
      );

      expect(decoded, isA<AgentSuccess>());
      expect((decoded as AgentSuccess).data, {'entries': []});
    });

    test('round-trips a failure with its message', () {
      final frame = const AgentFailure('replica lock held').toFrame(9);

      final decoded = AgentResult.fromFrame(frame);
      expect(frame.requestId, 9, reason: 'a reply answers under its own id');
      expect(decoded, isA<AgentFailure>());
      expect((decoded as AgentFailure).error, 'replica lock held');
    });
  });

  group('archiveEntryToJson / archiveEntryFromJson', () {
    test('round-trips', () {
      const entry = ArchiveEntry(
        path: 'a.txt',
        size: 5,
        mtime: 123,
        mode: 420,
        hash: 'deadbeef',
      );

      final decoded = archiveEntryFromJson(archiveEntryToJson(entry));

      expect(decoded.path, entry.path);
      expect(decoded.size, entry.size);
      expect(decoded.mtime, entry.mtime);
      expect(decoded.mode, entry.mode);
      expect(decoded.hash, entry.hash);
    });
  });

  group('fileMetadataToJson / fileMetadataFromJson', () {
    test('round-trips', () {
      const metadata = FileMetadata(size: 5, mtime: 123, mode: 420);

      final decoded = fileMetadataFromJson(fileMetadataToJson(metadata));

      expect(decoded.size, metadata.size);
      expect(decoded.mtime, metadata.mtime);
      expect(decoded.mode, metadata.mode);
    });
  });

  group('replicaSpecToJson / replicaSpecFromJson', () {
    test('round-trips', () {
      const spec = ReplicaSpec(
        rootPath: '~/notes',
        profileId: 'notes',
        side: 'a',
        jobs: 3,
      );

      final decoded = replicaSpecFromJson(replicaSpecToJson(spec));

      expect(decoded.rootPath, spec.rootPath);
      expect(decoded.profileId, spec.profileId);
      expect(decoded.side, spec.side);
      expect(decoded.jobs, spec.jobs);
    });
  });

  group('replicaInfoToJson / replicaInfoFromJson', () {
    test('round-trips a last-commit time', () {
      final info = ReplicaInfo(lastCommitTime: DateTime.utc(2024, 1, 1));

      final decoded = replicaInfoFromJson(replicaInfoToJson(info));

      // The instant survives the round trip; whether it comes back UTC or
      // local depends on `DateTime.fromMicrosecondsSinceEpoch`'s default, not
      // on anything this encoding controls.
      expect(
        decoded.lastCommitTime?.isAtSameMomentAs(DateTime.utc(2024, 1, 1)),
        isTrue,
      );
    });

    test('round-trips a null last-commit time', () {
      const info = ReplicaInfo();

      final decoded = replicaInfoFromJson(replicaInfoToJson(info));

      expect(decoded.lastCommitTime, isNull);
      expect(decoded.archivePath, isNull);
    });

    test('round-trips an archive path (task ee190c)', () {
      const info = ReplicaInfo(archivePath: '/state/notes-a.jsonl');

      final decoded = replicaInfoFromJson(replicaInfoToJson(info));

      expect(decoded.archivePath, '/state/notes-a.jsonl');
    });
  });

  group('ruleSetToJson / ruleSetFromJson', () {
    test('round-trips ignore and follow patterns', () {
      final rules = RuleSet(ignore: ['**/.git', '*.tmp'], follow: ['shared']);

      final decoded = ruleSetFromJson(ruleSetToJson(rules));

      expect(decoded.ignorePatterns, ['**/.git', '*.tmp']);
      expect(decoded.followPatterns, ['shared']);
      expect(decoded.ignores('sub/.git/config'), isTrue);
      expect(decoded.follows('shared'), isTrue);
    });

    test('round-trips an empty rule set', () {
      final decoded = ruleSetFromJson(ruleSetToJson(RuleSet()));

      expect(decoded.ignorePatterns, isEmpty);
      expect(decoded.followPatterns, isEmpty);
    });

    test('rejects a malformed pattern on decode', () {
      // Patterns cross the wire as written, so the peer compiles them itself
      // and refuses a bad one rather than trusting a foreign regex.
      expect(
        () => ruleSetFromJson({
          'ignore': ['a[bc'],
          'follow': <String>[],
        }),
        throwsFormatException,
      );
    });
  });

  group('sendByteStream / readByteStream', () {
    test('delivers every chunk then ends the stream', () async {
      final (sender, receiver) = _pairedChannels();

      unawaited(
        sendByteStream(
          sender,
          Stream.fromIterable([utf8.encode('hel'), utf8.encode('lo')]),
          requestId: 1,
        ),
      );

      final chunks = await readByteStream(_route(receiver, 1)).toList();

      expect(utf8.decode(chunks.expand((c) => c).toList()), 'hello');
    });

    test('skips empty chunks from the source without ending early', () async {
      final (sender, receiver) = _pairedChannels();

      unawaited(
        sendByteStream(
          sender,
          Stream.fromIterable([utf8.encode('a'), [], utf8.encode('b')]),
          requestId: 1,
        ),
      );

      final chunks = await readByteStream(_route(receiver, 1)).toList();

      expect(utf8.decode(chunks.expand((c) => c).toList()), 'ab');
    });

    test(
      'a source error surfaces to the reader as AgentOperationException',
      () async {
        final (sender, receiver) = _pairedChannels();

        Stream<List<int>> failing() async* {
          yield utf8.encode('partial');
          throw Exception('boom');
        }

        unawaited(sendByteStream(sender, failing(), requestId: 1));

        await expectLater(
          readByteStream(_route(receiver, 1)).toList(),
          throwsA(isA<AgentOperationException>()),
        );
      },
    );
  });
}

/// The route for request [requestId] on a running router over [channel] —
/// what `readByteStream` now reads, one exchange's frames rather than the
/// whole connection's (task 0f7dfc).
Stream<Frame> _route(Channel channel, int requestId) {
  final router = FrameRouter(channel.input);
  final route = router.open(requestId);
  unawaited(router.run(onUnrouted: (_, _) {}).catchError((_) {}));
  return route;
}

(Channel, Channel) _pairedChannels() {
  final aToB = StreamController<Uint8List>();
  final bToA = StreamController<Uint8List>();
  final a = _FakeChannel(outbox: aToB, input: bToA.stream);
  final b = _FakeChannel(outbox: bToA, input: aToB.stream);
  return (a, b);
}

/// A minimal [Channel] wiring two in-memory byte streams — just enough to
/// drive the protocol helpers in isolation. The real shared in-memory
/// `Channel` (SPEC §14) is a separate task; this one stays test-local.
class _FakeChannel implements Channel {
  final StreamController<Uint8List> outbox;
  @override
  final Stream<Uint8List> input;

  _FakeChannel({required this.outbox, required this.input});

  @override
  Future<void> send(Uint8List bytes) async {
    outbox.add(bytes);
  }

  @override
  Future<void> close() async {
    await outbox.close();
  }
}
