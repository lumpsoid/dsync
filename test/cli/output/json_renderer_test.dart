import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dsync/cli/output/human_renderer.dart';
import 'package:dsync/cli/output/json_renderer.dart';
import 'package:dsync/dsync_core/models/location.dart';
import 'package:dsync/dsync_core/models/plan.dart';
import 'package:dsync/dsync_core/models/replica_info.dart';
import 'package:dsync/dsync_core/models/run_event.dart';
import 'package:dsync/dsync_core/models/scan_entry.dart';
import 'package:test/test.dart';

/// An [IOSink] over an in-memory buffer, so a test reads what [JsonRenderer]
/// wrote without a real stdout/stderr.
///
/// Implements [StreamConsumer] directly (rather than forwarding through a
/// second [StreamController]) so its `addStream` only completes once every
/// chunk has actually been decoded into [_buffer] — `flush()` then really
/// means "everything written so far is in [_buffer]", with no async gap for
/// a scripted multi-event run to race.
class _BufferSink implements StreamConsumer<List<int>> {
  final StringBuffer _buffer = StringBuffer();
  late final IOSink sink = IOSink(this);

  @override
  Future<void> addStream(Stream<List<int>> stream) async {
    await for (final chunk in stream) {
      _buffer.write(utf8.decode(chunk));
    }
  }

  @override
  Future<void> close() async {}

  /// Flushes [sink] so every `write`/`writeln` so far has reached [_buffer],
  /// then returns its contents.
  Future<String> contents() async {
    await sink.flush();
    return _buffer.toString();
  }
}

/// One [JsonRenderer] plus its two buffers, so a test can build a renderer
/// and read both streams back without repeating the plumbing.
class _Rendered {
  final _BufferSink out = _BufferSink();
  final _BufferSink err = _BufferSink();
  late final JsonRenderer renderer;

  _Rendered({
    String profileId = 'test-profile',
    ReplicaDiagnostics? diagnosticsA,
    ReplicaDiagnostics? diagnosticsB,
  }) {
    renderer = JsonRenderer(
      out: out.sink,
      err: err.sink,
      profileId: profileId,
      diagnosticsA: diagnosticsA,
      diagnosticsB: diagnosticsB,
    );
  }
}

/// Renders [events] in order and returns the decoded object for each line,
/// after asserting stdout produced exactly one line per event and none of
/// it was left undecodable (SPEC §11.4: "one JSON object per line").
Future<List<Map<String, dynamic>>> _renderAll(
  _Rendered r,
  List<RunEvent> events,
) async {
  for (final event in events) {
    r.renderer.render(event);
  }
  final raw = await r.out.contents();
  // Splitting on '\n' after a trailing writeln leaves one empty trailing
  // element; every other element must be one decodable JSON object.
  final lines = raw.split('\n')..removeWhere((line) => line.isEmpty);
  expect(lines, hasLength(events.length));
  return lines.map((line) => jsonDecode(line) as Map<String, dynamic>).toList();
}

void main() {
  group('JsonRenderer', () {
    group('replicas (task ee190c)', () {
      final localDiagnostics = ReplicaDiagnostics(
        archivePath: '/state/notes-a.jsonl',
        lockPath: '/state/notes-a.lock',
        location: Location.parse('/home/me/notes'),
        locality: Locality.inProcess,
      );
      final remoteDiagnostics = ReplicaDiagnostics(
        archivePath: '/state/notes-b.jsonl',
        lockPath: '/state/notes-b.lock',
        location: Location.parse('me@phone:/sdcard/notes'),
        locality: Locality.remote,
      );

      test('carries each side\'s location, locality, resolved archive path, '
          'last-commit time, the profile id, and firstSync — facts, no '
          'prose', () async {
        final r = _Rendered(
          profileId: 'notes',
          diagnosticsA: localDiagnostics,
          diagnosticsB: remoteDiagnostics,
        );
        final event = RunReplicasEvent(
          infoA: ReplicaInfo(
            lastCommitTime: DateTime.utc(2026, 9, 10, 14, 3),
            archivePath: '/home/me/.local/state/dsync/notes-a.jsonl',
          ),
          infoB: const ReplicaInfo(),
        );

        final decoded = (await _renderAll(r, [event])).single;

        expect(decoded['type'], 'replicas');
        expect(decoded['profileId'], 'notes');
        expect(decoded['a'], {
          'location': {'path': '/home/me/notes'},
          'locality': 'inProcess',
          'archivePath': '/home/me/.local/state/dsync/notes-a.jsonl',
          'lastCommitTime': DateTime.utc(2026, 9, 10, 14, 3).toIso8601String(),
        });
        expect(decoded['b'], {
          'location': {'path': '/sdcard/notes', 'host': 'phone', 'user': 'me'},
          'locality': 'remote',
        });
        expect(decoded['firstSync'], isTrue);

        // No stray prose anywhere in the line.
        final raw = jsonEncode(decoded);
        expect(raw, isNot(contains('first sync of this pair')));
        expect(raw, isNot(contains('never deleted')));
      });

      test('firstSync is false once both sides have committed', () async {
        final r = _Rendered();
        final event = RunReplicasEvent(
          infoA: ReplicaInfo(lastCommitTime: DateTime.utc(2026, 1, 1)),
          infoB: ReplicaInfo(lastCommitTime: DateTime.utc(2026, 1, 2)),
        );

        final decoded = (await _renderAll(r, [event])).single;

        expect(decoded['firstSync'], isFalse);
      });
    });

    test(
      'plan: actions and conflicts, each shaped like their own line type',
      () async {
        final r = _Rendered();
        const event = RunPlanEvent(
          Plan(
            actions: [
              PlanAction(path: 'a.txt', type: ActionType.copyAtoB, bytes: 10),
              PlanAction(path: 'b.txt', type: ActionType.deleteOnB),
            ],
            conflicts: [
              Conflict(
                path: 'c.txt',
                onA: ScanEntry(path: 'c.txt', reason: ScanReason.modified),
                onB: ScanEntry(path: 'c.txt', reason: ScanReason.deleted),
              ),
              Conflict(
                path: 'd.txt',
                onB: ScanEntry(path: 'd.txt', reason: ScanReason.created),
              ),
            ],
          ),
        );

        final decoded = (await _renderAll(r, [event])).single;

        expect(decoded['type'], 'plan');
        expect(decoded['actions'], [
          {'path': 'a.txt', 'actionType': 'copyAtoB', 'bytes': 10},
          {'path': 'b.txt', 'actionType': 'deleteOnB', 'bytes': 0},
        ]);
        expect(decoded['conflicts'], [
          {
            'path': 'c.txt',
            'onA': 'modified',
            'onAReason': 'modified',
            'onB': 'deleted',
            'onBReason': 'deleted',
          },
          {'path': 'd.txt', 'onB': 'created', 'onBReason': 'created'},
        ]);
        // A side with no record at all omits its key (and its reason) rather
        // than emitting `null` (matches control_message.dart's `*ToJson`
        // null-omission convention).
        final lastConflict = (decoded['conflicts'] as List).last;
        expect(lastConflict, isNot(contains('onA')));
        expect(lastConflict, isNot(contains('onAReason')));
      },
    );

    test('symlink: path and which side it was found on', () async {
      final r = _Rendered();

      final decoded = (await _renderAll(r, [
        const RunSkippedSymlinkEvent(path: 'link', onA: true),
        const RunSkippedSymlinkEvent(path: 'other-link', onA: false),
      ]));

      expect(decoded[0], {'type': 'symlink', 'path': 'link', 'onA': true});
      expect(decoded[1], {
        'type': 'symlink',
        'path': 'other-link',
        'onA': false,
      });
    });

    test('conflict: path and each side\'s status and reason', () async {
      final r = _Rendered();
      const event = RunConflictEvent(
        Conflict(
          path: 'c.txt',
          onA: ScanEntry(path: 'c.txt', reason: ScanReason.modified),
          onB: ScanEntry(path: 'c.txt', reason: ScanReason.deleted),
        ),
      );

      final decoded = (await _renderAll(r, [event])).single;

      expect(decoded, {
        'type': 'conflict',
        'path': 'c.txt',
        'onA': 'modified',
        'onAReason': 'modified',
        'onB': 'deleted',
        'onBReason': 'deleted',
      });
    });

    test("conflict: a side's reason distinguishes ScanStatus.unchanged's two "
        'possible causes (SPEC §5.2), unlike its status alone', () async {
      final r = _Rendered();
      const event = RunConflictEvent(
        Conflict(
          path: 'c.txt',
          onA: ScanEntry(path: 'c.txt', reason: ScanReason.metadataMatched),
          onB: ScanEntry(path: 'c.txt', reason: ScanReason.hashMatched),
        ),
      );

      final decoded = (await _renderAll(r, [event])).single;

      expect(decoded['onA'], 'unchanged');
      expect(decoded['onAReason'], 'metadataMatched');
      expect(decoded['onB'], 'unchanged');
      expect(decoded['onBReason'], 'hashMatched');
    });

    test('conflict: a side with no record omits its key, not a null', () async {
      final r = _Rendered();
      const event = RunConflictEvent(
        Conflict(
          path: 'new.txt',
          onB: ScanEntry(path: 'new.txt', reason: ScanReason.created),
        ),
      );

      final decoded = (await _renderAll(r, [event])).single;

      expect(decoded.containsKey('onA'), isFalse);
      expect(decoded.containsKey('onAReason'), isFalse);
      expect(decoded['onB'], 'created');
      expect(decoded['onBReason'], 'created');
    });

    test('action: path, action type, and bytes moved', () async {
      final r = _Rendered();
      const event = RunActionEvent(
        PlanAction(path: 'a.txt', type: ActionType.copyAtoB, bytes: 42),
      );

      final decoded = (await _renderAll(r, [event])).single;

      expect(decoded, {
        'type': 'action',
        'path': 'a.txt',
        'actionType': 'copyAtoB',
        'bytes': 42,
      });
    });

    test('progress: completed and total counts', () async {
      final r = _Rendered();
      const event = RunProgressEvent(completed: 3, total: 10);

      final decoded = (await _renderAll(r, [event])).single;

      expect(decoded, {'type': 'progress', 'completed': 3, 'total': 10});
    });

    test('result: a succeeded path carries no error', () async {
      final r = _Rendered();
      const event = RunResultEvent(path: 'a.txt', type: ActionType.copyAtoB);

      final decoded = (await _renderAll(r, [event])).single;

      expect(decoded, {
        'type': 'result',
        'path': 'a.txt',
        'actionType': 'copyAtoB',
        'succeeded': true,
      });
      expect(decoded.containsKey('error'), isFalse);
    });

    test('result: a failed path carries the error\'s toString()', () async {
      final r = _Rendered();
      final event = RunResultEvent(
        path: 'b.txt',
        type: ActionType.deleteOnA,
        error: Exception('disk full'),
      );

      final decoded = (await _renderAll(r, [event])).single;

      expect(decoded['type'], 'result');
      expect(decoded['path'], 'b.txt');
      expect(decoded['actionType'], 'deleteOnA');
      expect(decoded['succeeded'], false);
      expect(decoded['error'], Exception('disk full').toString());
    });

    test('summary: the four counts', () async {
      final r = _Rendered();
      const event = RunSummaryEvent(
        appliedCount: 5,
        failedCount: 1,
        conflictCount: 2,
        skippedCount: 3,
      );

      final decoded = (await _renderAll(r, [event])).single;

      expect(decoded, {
        'type': 'summary',
        'appliedCount': 5,
        'failedCount': 1,
        'conflictCount': 2,
        'skippedCount': 3,
      });
    });

    test('error: the error\'s toString() as message', () async {
      final r = _Rendered();
      final event = RunErrorEvent(StateError('replica lock held'));

      final decoded = (await _renderAll(r, [event])).single;

      expect(decoded, {
        'type': 'error',
        'message': StateError('replica lock held').toString(),
      });
    });

    test('a full scripted run: one decodable line per event, in order, '
        'and nothing but JSON on stdout', () async {
      final r = _Rendered();
      final events = <RunEvent>[
        const RunSkippedSymlinkEvent(path: 'link', onA: true),
        const RunConflictEvent(
          Conflict(
            path: 'c.txt',
            onA: ScanEntry(path: 'c.txt', reason: ScanReason.modified),
            onB: ScanEntry(path: 'c.txt', reason: ScanReason.deleted),
          ),
        ),
        const RunPlanEvent(
          Plan(
            actions: [PlanAction(path: 'a.txt', type: ActionType.copyAtoB)],
            conflicts: [],
          ),
        ),
        const RunActionEvent(
          PlanAction(path: 'a.txt', type: ActionType.copyAtoB),
        ),
        const RunProgressEvent(completed: 1, total: 1),
        const RunResultEvent(path: 'a.txt', type: ActionType.copyAtoB),
        const RunSummaryEvent(
          appliedCount: 1,
          failedCount: 0,
          conflictCount: 1,
          skippedCount: 0,
        ),
        RunErrorEvent(StateError('fatal')),
      ];

      final decoded = await _renderAll(r, events);

      expect(decoded.map((d) => d['type']), [
        'symlink',
        'conflict',
        'plan',
        'action',
        'progress',
        'result',
        'summary',
        'error',
      ]);
      // Every event went to stdout as JSON; nothing reached stderr.
      expect(await r.err.contents(), isEmpty);
    });
  });
}
