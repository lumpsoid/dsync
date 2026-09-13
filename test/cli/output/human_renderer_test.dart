import 'dart:convert';
import 'dart:io';

import 'package:dsync/cli/options/verbosity.dart';
import 'package:dsync/cli/output/human_renderer.dart';
import 'package:dsync/dsync_core/models/plan.dart';
import 'package:dsync/dsync_core/models/rule_set.dart';
import 'package:dsync/dsync_core/models/run_event.dart';
import 'package:dsync/dsync_core/models/scan_entry.dart';
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
  }) {
    renderer = HumanRenderer(
      out: out,
      err: err,
      verbosity: verbosity,
      warnSizeBytes: warnSizeBytes,
      rules: rules,
      diagnosticsA: diagnosticsA,
      diagnosticsB: diagnosticsB,
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
    onA: ScanEntry(path: 'c.txt', status: ScanStatus.modified),
    onB: ScanEntry(path: 'c.txt', status: ScanStatus.deleted),
  ),
);

void main() {
  group('HumanRenderer, Verbosity.quiet (task e9b4b6 DECIDED)', () {
    test('prints only the summary line, nothing else', () {
      final r = _Rendered(verbosity: Verbosity.quiet);
      r.renderer.render(_conflict);
      r.renderer.render(_plan);
      r.renderer.render(const RunSkippedSymlinkEvent(path: 'link', onA: true));
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

    test('renders a skipped symlink for each side (SPEC §5.1)', () {
      final r = _Rendered();
      r.renderer.render(
        const RunSkippedSymlinkEvent(path: 'on-a-link', onA: true),
      );
      r.renderer.render(
        const RunSkippedSymlinkEvent(path: 'on-b-link', onA: false),
      );

      final output = r.out.buffer.toString();
      expect(output, contains('on-a-link'));
      expect(output, contains('on-b-link'));
    });

    test('distinguishes which side a skipped symlink was found on', () {
      final onA = _Rendered();
      onA.renderer.render(
        const RunSkippedSymlinkEvent(path: 'link', onA: true),
      );
      final onB = _Rendered();
      onB.renderer.render(
        const RunSkippedSymlinkEvent(path: 'link', onA: false),
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
        ),
      );

      final output = r.out.buffer.toString();
      expect(output, contains('3'));
      expect(output, contains('1'));
      expect(output, contains('2'));
      expect(output, contains('4'));
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

  group('HumanRenderer, Verbosity.verbose', () {
    test('shows at least everything normal shows', () {
      final r = _Rendered(verbosity: Verbosity.verbose);
      r.renderer.render(_conflict);
      r.renderer.render(_plan);
      r.renderer.render(const RunSkippedSymlinkEvent(path: 'link', onA: true));

      final output = r.out.buffer.toString();
      expect(output, contains('c.txt'));
      expect(output, contains('a.txt'));
      expect(output, contains('link'));
    });
  });

  group('HumanRenderer.renderPreamble (task e9b4b6 DECIDED verbose set)', () {
    final rules = RuleSet(ignore: const ['*.tmp'], follow: const ['links/**']);
    const remoteDiagnostics = ReplicaDiagnostics(
      archivePath: '/state/profile-a.jsonl',
      lockPath: '/state/profile-a.lock',
      sshArgs: ['-T', 'user@host', 'dsync', 'agent', '--stdio'],
    );
    const localDiagnostics = ReplicaDiagnostics(
      archivePath: '/state/profile-b.jsonl',
      lockPath: '/state/profile-b.lock',
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
