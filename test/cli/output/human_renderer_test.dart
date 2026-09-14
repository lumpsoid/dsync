import 'dart:convert';
import 'dart:io';

import 'package:dsync/cli/options/verbosity.dart';
import 'package:dsync/cli/output/human_renderer.dart';
import 'package:dsync/dsync_core/models/location.dart';
import 'package:dsync/dsync_core/models/plan.dart';
import 'package:dsync/dsync_core/models/replica_info.dart';
import 'package:dsync/dsync_core/models/rule_set.dart';
import 'package:dsync/dsync_core/models/run_event.dart';
import 'package:dsync/dsync_core/models/scan_entry.dart';
import 'package:dsync/dsync_core/models/scan_result.dart';
import 'package:dsync/dsync_core/models/skipped_path.dart';
import 'package:test/test.dart';

/// A synchronous fake [IOSink] backed by a [StringBuffer], so a test reads
/// exactly what [HumanRenderer] wrote — no TTY, no real stdout/stderr, and
/// no stream-scheduling race to wait out: every `write`/`writeln` lands in
/// [buffer] before the call returns.
class _BufferSink implements IOSink {
  final StringBuffer buffer = StringBuffer();

  @override
  Encoding encoding = utf8;

  @override
  void write(Object? object) => buffer.write(object);

  @override
  void writeAll(Iterable objects, [String separator = '']) =>
      buffer.writeAll(objects, separator);

  @override
  void writeCharCode(int charCode) => buffer.writeCharCode(charCode);

  @override
  void writeln([Object? object = '']) => buffer.writeln(object);

  @override
  void add(List<int> data) => buffer.write(utf8.decode(data));

  @override
  void addError(Object error, [StackTrace? stackTrace]) {}

  @override
  Future<void> addStream(Stream<List<int>> stream) async {
    await for (final chunk in stream) {
      add(chunk);
    }
  }

  @override
  Future<void> close() async {}

  @override
  Future<void> get done => Future.value();

  @override
  Future<void> flush() async {}
}

/// One [HumanRenderer] plus its two buffers, so a test builds a renderer and
/// reads both streams back without repeating the plumbing.
class _Rendered {
  final _BufferSink out = _BufferSink();
  final _BufferSink err = _BufferSink();
  late final HumanRenderer renderer;

  _Rendered({
    Verbosity verbosity = Verbosity.normal,
    int? warnSizeBytes,
    RuleSet? rules,
    ReplicaDiagnostics? diagnosticsA,
    ReplicaDiagnostics? diagnosticsB,
    String profileId = 'test-profile',
    bool isAdHoc = false,
    DateTime Function()? now,
  }) {
    renderer = HumanRenderer(
      out: out,
      err: err,
      verbosity: verbosity,
      warnSizeBytes: warnSizeBytes,
      rules: rules,
      diagnosticsA: diagnosticsA,
      diagnosticsB: diagnosticsB,
      profileId: profileId,
      isAdHoc: isAdHoc,
      now: now ?? DateTime.now,
    );
  }
}

const _plan = RunPlanEvent(
  Plan(
    actions: [
      PlanAction(path: 'a.txt', type: ActionType.copyAtoB, bytes: 10),
      PlanAction(path: 'b.txt', type: ActionType.deleteOnB),
    ],
    conflicts: [],
  ),
);

const _conflict = RunConflictEvent(
  Conflict(
    path: 'c.txt',
    onA: ScanEntry(path: 'c.txt', reason: ScanReason.modified),
    onB: ScanEntry(path: 'c.txt', reason: ScanReason.deleted),
  ),
);

void main() {
  group('HumanRenderer, Verbosity.quiet (task e9b4b6 DECIDED)', () {
    test('prints only the summary line, nothing else', () {
      final r = _Rendered(verbosity: Verbosity.quiet);
      r.renderer.render(_conflict);
      r.renderer.render(_plan);
      r.renderer.render(
        const RunSkippedPathEvent(
          skipped: SkippedPath.symlink('link'),
          onA: true,
        ),
      );
      r.renderer.render(
        const RunActionEvent(
          PlanAction(path: 'a.txt', type: ActionType.copyAtoB),
        ),
      );
      r.renderer.render(
        const RunResultEvent(path: 'a.txt', type: ActionType.copyAtoB),
      );
      r.renderer.render(const RunProgressEvent(completed: 1, total: 1));
      r.renderer.render(
        const RunSummaryEvent(
          appliedCount: 1,
          failedCount: 0,
          conflictCount: 1,
          skippedCount: 0,
          unreadableCount: 0,
        ),
      );

      final output = r.out.buffer.toString();
      expect(output, contains('summary:'));
      // 'conflict' itself isn't checked here: the summary line legitimately
      // says "conflicts=1". The conflict's own path is what must not leak.
      expect(output, isNot(contains('c.txt')));
      expect(output, isNot(contains('plan:')));
      expect(output, isNot(contains('symlink')));
      expect(output, isNot(contains('a.txt')));
    });

    test('still prints an error', () {
      final r = _Rendered(verbosity: Verbosity.quiet);
      r.renderer.render(const RunErrorEvent('lock held'));

      expect(r.err.buffer.toString(), contains('lock held'));
    });

    test('an error goes to err, not out', () {
      final r = _Rendered(verbosity: Verbosity.quiet);
      r.renderer.render(const RunErrorEvent('boom'));

      expect(r.out.buffer.toString(), isEmpty);
      expect(r.err.buffer.toString(), contains('boom'));
    });

    test('the summary still carries the unreadable count (task 37bf4f): the '
        'per-path lines are silenced here, so without it a quiet run that '
        'failed to read half the tree would look like one that read all '
        'of it', () {
      final r = _Rendered(verbosity: Verbosity.quiet);
      r.renderer.render(
        const RunSkippedPathEvent(
          skipped: SkippedPath.unreadable('locked.txt', 'Permission denied'),
          onA: true,
        ),
      );
      r.renderer.render(
        const RunSummaryEvent(
          appliedCount: 1,
          failedCount: 0,
          conflictCount: 0,
          skippedCount: 0,
          unreadableCount: 1,
        ),
      );

      final output = r.out.buffer.toString();
      expect(output, isNot(contains('locked.txt')));
      expect(output, contains('unreadable=1'));
    });
  });

  group('HumanRenderer, Verbosity.normal', () {
    test('renders every action in the plan table', () {
      final r = _Rendered();
      r.renderer.render(_plan);

      final output = r.out.buffer.toString();
      expect(output, contains('a.txt'));
      expect(output, contains('b.txt'));
    });

    test('renders a conflict', () {
      final r = _Rendered();
      r.renderer.render(_conflict);

      expect(r.out.buffer.toString(), contains('c.txt'));
    });

    test('does not show the reason behind either side\'s status '
        '(verbose-only, SPEC §11.4, task 8a3ff1)', () {
      final r = _Rendered();
      r.renderer.render(_conflict);

      expect(
        r.out.buffer.toString(),
        isNot(contains('rehash differed from archive')),
      );
    });

    test('renders a skipped symlink for each side (SPEC §5.1)', () {
      final r = _Rendered();
      r.renderer.render(
        const RunSkippedPathEvent(
          skipped: SkippedPath.symlink('on-a-link'),
          onA: true,
        ),
      );
      r.renderer.render(
        const RunSkippedPathEvent(
          skipped: SkippedPath.symlink('on-b-link'),
          onA: false,
        ),
      );

      final output = r.out.buffer.toString();
      expect(output, contains('on-a-link'));
      expect(output, contains('on-b-link'));
    });

    test('an unreadable path says outright that it did not sync, and why '
        '(SPEC §5, task 37bf4f) — a user who reads "skipped" and moves on '
        'is a user who believes a file synced when it never did', () {
      final r = _Rendered();
      r.renderer.render(
        const RunSkippedPathEvent(
          skipped: SkippedPath.unreadable('locked.txt', 'Permission denied'),
          onA: true,
        ),
      );

      final output = r.out.buffer.toString();
      expect(output, contains('locked.txt'));
      expect(output, contains('Permission denied'));
      expect(output, contains('not synced'));
    });

    test('an unreadable path does not read as a skipped symlink: they are '
        'different outcomes and the line says which', () {
      final symlink = _Rendered();
      symlink.renderer.render(
        const RunSkippedPathEvent(skipped: SkippedPath.symlink('p'), onA: true),
      );
      final unreadable = _Rendered();
      unreadable.renderer.render(
        const RunSkippedPathEvent(
          skipped: SkippedPath.unreadable('p', 'Permission denied'),
          onA: true,
        ),
      );

      expect(symlink.out.buffer.toString(), contains('symlink'));
      expect(unreadable.out.buffer.toString(), contains('unreadable'));
      expect(unreadable.out.buffer.toString(), isNot(contains('symlink')));
    });

    test('distinguishes which side a skipped symlink was found on', () {
      final onA = _Rendered();
      onA.renderer.render(
        const RunSkippedPathEvent(
          skipped: SkippedPath.symlink('link'),
          onA: true,
        ),
      );
      final onB = _Rendered();
      onB.renderer.render(
        const RunSkippedPathEvent(
          skipped: SkippedPath.symlink('link'),
          onA: false,
        ),
      );

      expect(
        onA.out.buffer.toString(),
        isNot(equals(onB.out.buffer.toString())),
      );
    });

    test('conflicts print before the plan table when rendered in that '
        'order (SPEC §11.3)', () {
      final r = _Rendered();
      r.renderer.render(_conflict);
      r.renderer.render(_plan);

      final output = r.out.buffer.toString();
      expect(output.indexOf('c.txt'), lessThan(output.indexOf('plan:')));
    });

    test('a progress line appears during apply', () {
      final r = _Rendered();
      r.renderer.render(const RunProgressEvent(completed: 2, total: 5));

      final output = r.out.buffer.toString();
      expect(output, contains('2'));
      expect(output, contains('5'));
    });

    test('a failed result includes its error', () {
      final r = _Rendered();
      r.renderer.render(
        const RunResultEvent(
          path: 'bad.txt',
          type: ActionType.copyAtoB,
          error: 'disk full',
        ),
      );

      final output = r.out.buffer.toString();
      expect(output, contains('bad.txt'));
      expect(output, contains('disk full'));
    });

    test('the summary always renders', () {
      final r = _Rendered();
      r.renderer.render(
        const RunSummaryEvent(
          appliedCount: 3,
          failedCount: 1,
          conflictCount: 2,
          skippedCount: 4,
          unreadableCount: 5,
        ),
      );

      final output = r.out.buffer.toString();
      expect(output, contains('applied=3'));
      expect(output, contains('failed=1'));
      expect(output, contains('conflicts=2'));
      expect(output, contains('skipped=4'));
      expect(output, contains('unreadable=5'));
    });

    test('unreadable is its own count, not folded into skipped (task '
        '37bf4f): "skipped" means the user was offered this and declined, '
        'and an unreadable path was never offered', () {
      final r = _Rendered();
      r.renderer.render(
        const RunSummaryEvent(
          appliedCount: 0,
          failedCount: 0,
          conflictCount: 0,
          skippedCount: 0,
          unreadableCount: 2,
        ),
      );

      final output = r.out.buffer.toString();
      expect(output, contains('skipped=0'));
      expect(output, contains('unreadable=2'));
    });
  });

  group('HumanRenderer size warning (SPEC §10)', () {
    test('does not warn when under warnSizeBytes', () {
      final r = _Rendered(warnSizeBytes: 1000);
      r.renderer.render(_plan); // 10 bytes total

      expect(r.out.buffer.toString(), isNot(contains('warning')));
    });

    test('warns when over warnSizeBytes, but still renders the plan '
        '(nothing is blocked)', () {
      final r = _Rendered(warnSizeBytes: 5);
      r.renderer.render(_plan); // 10 bytes total

      final output = r.out.buffer.toString();
      expect(output, contains('warning'));
      expect(output, contains('a.txt'));
      expect(output, contains('b.txt'));
    });

    test('never warns when warnSizeBytes is null (not configured)', () {
      final r = _Rendered(warnSizeBytes: null);
      r.renderer.render(_plan);

      expect(r.out.buffer.toString(), isNot(contains('warning')));
    });

    test('does not warn at exactly the threshold', () {
      final r = _Rendered(warnSizeBytes: 10);
      r.renderer.render(_plan); // exactly 10 bytes total

      expect(r.out.buffer.toString(), isNot(contains('warning')));
    });
  });

  group('HumanRenderer.render(RunReplicasEvent) (task ee190c: run header)', () {
    final fixedNow = DateTime.utc(2026, 9, 13, 12, 0);
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
      sshArgs: const ['-T', 'me@phone', 'dsync', 'agent', '--stdio'],
    );

    test('a profile run with both sides synced shows the profile name, both '
        'rows, and last synced', () {
      final r = _Rendered(
        diagnosticsA: localDiagnostics,
        diagnosticsB: remoteDiagnostics,
        profileId: 'notes',
        now: () => fixedNow,
      );
      r.renderer.render(
        RunReplicasEvent(
          infoA: ReplicaInfo(
            lastCommitTime: fixedNow.subtract(const Duration(days: 3)),
          ),
          infoB: ReplicaInfo(
            lastCommitTime: fixedNow.subtract(const Duration(days: 3)),
          ),
        ),
      );

      final output = r.out.buffer.toString();
      expect(output, contains('profile notes'));
      expect(output, contains('/home/me/notes'));
      expect(output, contains('local'));
      expect(output, contains('me@phone:/sdcard/notes'));
      expect(output, contains('ssh'));
      expect(output, contains('last synced'));
      expect(output, contains('3 day(s) ago'));
    });

    test('a true first sync (both sides empty) says so and carries the '
        'warning note', () {
      final r = _Rendered(profileId: 'notes');
      r.renderer.render(
        const RunReplicasEvent(infoA: ReplicaInfo(), infoB: ReplicaInfo()),
      );

      final output = r.out.buffer.toString();
      expect(output, contains('first sync of this pair'));
      expect(output, contains('First sync:'));
      expect(output, isNot(contains('has no archive yet')));
    });

    test('the asymmetric case (one archive, one none) is flagged distinctly '
        'from the both-empty case', () {
      final r = _Rendered(profileId: 'notes');
      r.renderer.render(
        RunReplicasEvent(
          infoA: const ReplicaInfo(),
          infoB: ReplicaInfo(lastCommitTime: DateTime.utc(2026, 1, 1)),
        ),
      );

      final output = r.out.buffer.toString();
      expect(output, contains('first sync of this pair'));
      expect(output, contains('A has no archive yet'));
      expect(output, contains('First sync:'));
    });

    test('an ad-hoc run shows its derived id next to the summary line, not '
        'as a "profile" header', () {
      final r = _Rendered(profileId: 'adhoc-3f2a9c1b7e4d0a85', isAdHoc: true);
      r.renderer.render(
        const RunReplicasEvent(infoA: ReplicaInfo(), infoB: ReplicaInfo()),
      );

      final output = r.out.buffer.toString();
      expect(output, isNot(contains('profile adhoc-3f2a9c1b7e4d0a85')));
      expect(
        output,
        contains('adhoc-3f2a9c1b7e4d0a85 · first sync of this pair'),
      );
    });

    test('--quiet shows none of it', () {
      final r = _Rendered(
        verbosity: Verbosity.quiet,
        profileId: 'notes',
        diagnosticsA: localDiagnostics,
        diagnosticsB: remoteDiagnostics,
      );
      r.renderer.render(
        RunReplicasEvent(
          infoA: ReplicaInfo(lastCommitTime: DateTime.utc(2026, 1, 1)),
          infoB: ReplicaInfo(lastCommitTime: DateTime.utc(2026, 1, 1)),
        ),
      );

      expect(r.out.buffer.toString(), isEmpty);
    });

    test('renders only what is present, without throwing, when diagnostics '
        'are missing', () {
      final r = _Rendered(profileId: 'notes');

      expect(
        () => r.renderer.render(
          RunReplicasEvent(
            infoA: ReplicaInfo(lastCommitTime: DateTime.utc(2026, 1, 1)),
            infoB: ReplicaInfo(lastCommitTime: DateTime.utc(2026, 1, 1)),
          ),
        ),
        returnsNormally,
      );
      expect(r.out.buffer.toString(), isNot(contains('A  ')));
    });
  });

  group('HumanRenderer, Verbosity.verbose', () {
    test('shows at least everything normal shows', () {
      final r = _Rendered(verbosity: Verbosity.verbose);
      r.renderer.render(_conflict);
      r.renderer.render(_plan);
      r.renderer.render(
        const RunSkippedPathEvent(
          skipped: SkippedPath.symlink('link'),
          onA: true,
        ),
      );

      final output = r.out.buffer.toString();
      expect(output, contains('c.txt'));
      expect(output, contains('a.txt'));
      expect(output, contains('link'));
    });

    test('shows the reason behind each side\'s status on a conflict line '
        '(SPEC §11.4, task 8a3ff1)', () {
      final r = _Rendered(verbosity: Verbosity.verbose);
      r.renderer.render(_conflict);

      final output = r.out.buffer.toString();
      // _conflict: onA is ScanReason.modified, onB is ScanReason.deleted.
      expect(output, contains('rehash differed from archive'));
      expect(output, contains('archive entry, file absent'));
    });

    test('distinguishes ScanStatus.unchanged\'s two reasons, which a bare '
        'status cannot (SPEC §5.2: fast path vs. a rehash that matched)', () {
      const conflict = RunConflictEvent(
        Conflict(
          path: 'c.txt',
          onA: ScanEntry(path: 'c.txt', reason: ScanReason.metadataMatched),
          onB: ScanEntry(path: 'c.txt', reason: ScanReason.hashMatched),
        ),
      );
      final r = _Rendered(verbosity: Verbosity.verbose);
      r.renderer.render(conflict);

      final output = r.out.buffer.toString();
      expect(output, contains('size/mtime matched archive, not rehashed'));
      expect(output, contains('size/mtime drifted, rehash matched archive'));
    });
  });

  group(
    'HumanRenderer.render(RunScanTallyEvent) (SPEC §5.2, §11.4, task 1fd42b)',
    () {
      const scanTally = RunScanTallyEvent(
        tallyA: ScanReasonTally(
          metadataMatched: 47,
          hashMatched: 3,
          modified: 0,
          created: 0,
          deleted: 0,
        ),
        tallyB: ScanReasonTally(
          metadataMatched: 10,
          hashMatched: 38,
          modified: 0,
          created: 0,
          deleted: 0,
        ),
      );

      test('is silent at Verbosity.quiet', () {
        final r = _Rendered(verbosity: Verbosity.quiet);
        r.renderer.render(scanTally);

        expect(r.out.buffer.toString(), isEmpty);
      });

      test('is silent at Verbosity.normal, unlike most other events', () {
        final r = _Rendered();
        r.renderer.render(scanTally);

        expect(r.out.buffer.toString(), isEmpty);
      });

      test('at Verbosity.verbose, shows each side\'s total scanned and how '
          'many it had to rehash to confirm unchanged', () {
        final r = _Rendered(verbosity: Verbosity.verbose);
        r.renderer.render(scanTally);

        final output = r.out.buffer.toString();
        expect(output, contains('scan A'));
        expect(output, contains('50 path(s) scanned'));
        expect(output, contains('3 rehashed'));
        expect(output, contains('scan B'));
        expect(output, contains('48 path(s) scanned'));
        expect(output, contains('38 rehashed'));
      });

      test('a side that never needed a rehash still shows a zero, not a '
          'missing line', () {
        final r = _Rendered(verbosity: Verbosity.verbose);
        r.renderer.render(
          const RunScanTallyEvent(
            tallyA: ScanReasonTally(
              metadataMatched: 5,
              hashMatched: 0,
              modified: 0,
              created: 0,
              deleted: 0,
            ),
            tallyB: ScanReasonTally(
              metadataMatched: 5,
              hashMatched: 0,
              modified: 0,
              created: 0,
              deleted: 0,
            ),
          ),
        );

        final output = r.out.buffer.toString();
        expect(output, contains('scan A'));
        expect(output, contains('scan B'));
        expect(output, contains('0 rehashed'));
      });
    },
  );

  group('HumanRenderer.renderPreamble (task e9b4b6 DECIDED verbose set)', () {
    final rules = RuleSet(ignore: const ['*.tmp'], follow: const ['links/**']);
    final remoteDiagnostics = ReplicaDiagnostics(
      archivePath: '/state/profile-a.jsonl',
      lockPath: '/state/profile-a.lock',
      location: Location.parse('user@host:/notes'),
      locality: Locality.remote,
      sshArgs: const ['-T', 'user@host', 'dsync', 'agent', '--stdio'],
    );
    final localDiagnostics = ReplicaDiagnostics(
      archivePath: '/state/profile-b.jsonl',
      lockPath: '/state/profile-b.lock',
      location: Location.parse('/home/me/notes'),
      locality: Locality.inProcess,
    );

    test('at verbose, shows the merged ignore/follow rules', () {
      final r = _Rendered(verbosity: Verbosity.verbose, rules: rules);
      r.renderer.renderPreamble();

      final output = r.out.buffer.toString();
      expect(output, contains('*.tmp'));
      expect(output, contains('links/**'));
    });

    test('at verbose, shows both sides\' archive and lock paths', () {
      final r = _Rendered(
        verbosity: Verbosity.verbose,
        diagnosticsA: remoteDiagnostics,
        diagnosticsB: localDiagnostics,
      );
      r.renderer.renderPreamble();

      final output = r.out.buffer.toString();
      expect(output, contains('/state/profile-a.jsonl'));
      expect(output, contains('/state/profile-a.lock'));
      expect(output, contains('/state/profile-b.jsonl'));
      expect(output, contains('/state/profile-b.lock'));
    });

    test('at verbose, shows the ssh argv for a remote side', () {
      final r = _Rendered(
        verbosity: Verbosity.verbose,
        diagnosticsA: remoteDiagnostics,
      );
      r.renderer.renderPreamble();

      expect(r.out.buffer.toString(), contains('user@host'));
    });

    test('at verbose, a local side (no sshArgs) shows no ssh argv line', () {
      final r = _Rendered(
        verbosity: Verbosity.verbose,
        diagnosticsB: localDiagnostics,
      );
      r.renderer.renderPreamble();

      expect(r.out.buffer.toString(), isNot(contains('ssh')));
    });

    test('renders only what is present, without throwing, when some '
        'diagnostics are missing', () {
      final r = _Rendered(
        verbosity: Verbosity.verbose,
        diagnosticsA: remoteDiagnostics,
        // diagnosticsB and rules deliberately absent.
      );

      expect(r.renderer.renderPreamble, returnsNormally);
      expect(r.out.buffer.toString(), contains('profile-a'));
    });

    test('is a no-op at Verbosity.normal, even with everything available', () {
      final r = _Rendered(
        verbosity: Verbosity.normal,
        rules: rules,
        diagnosticsA: remoteDiagnostics,
        diagnosticsB: localDiagnostics,
      );
      r.renderer.renderPreamble();

      expect(r.out.buffer.toString(), isEmpty);
    });

    test('is a no-op at Verbosity.quiet, even with everything available', () {
      final r = _Rendered(
        verbosity: Verbosity.quiet,
        rules: rules,
        diagnosticsA: remoteDiagnostics,
        diagnosticsB: localDiagnostics,
      );
      r.renderer.renderPreamble();

      expect(r.out.buffer.toString(), isEmpty);
    });
  });
}
