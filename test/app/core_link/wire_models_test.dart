import 'package:dsync/app/core_link/models/action_choice.dart';
import 'package:dsync/app/core_link/models/conflict_choice.dart';
import 'package:dsync/app/core_link/models/file_status.dart';
import 'package:dsync/app/core_link/models/plan_action.dart';
import 'package:dsync/app/core_link/models/replica_side.dart';
import 'package:dsync/app/core_link/models/run_intent.dart';
import 'package:dsync/app/core_link/models/run_phase.dart';
import 'package:dsync/app/core_link/wire_models.dart' as link;
import 'package:dsync/app/rust/bindings/bindings.dart' as wire;
import 'package:flutter_test/flutter_test.dart';

import '../features/run/run_fixtures.dart';

/// The generated signal classes read as the head's models, and the head's
/// intents written back: plain values both ways, no native library.
void main() {
  test('a view reads with its plan, conflicts, offers and sizes', () {
    final view = runView(
      conflicts: [
        conflictRow(
          'c.txt',
          a: wire.StatusViewModified(
            value: wire.FileView(size: n(3), mtimeUs: 9),
          ),
          b: const wire.StatusViewDeleted(),
          offered: const [
            wire.ConflictChoiceView.unresolved,
            wire.ConflictChoiceView.keepA,
            wire.ConflictChoiceView.keepB,
          ],
          choice: wire.ConflictChoiceView.keepB,
        ),
      ],
      plan: [
        planRow(copyTo('a.txt', bytes: 5), reverseBytes: 4),
        planRow(deleteThere('b.txt'), choice: wire.ActionChoiceView.skipped),
      ],
    );

    final read = link.runView(view);
    expect(read.bytesToTransfer, 5);
    final [a, b] = read.plan;
    expect(
      a.proposal.action,
      isA<CopyAction>()
          .having((a) => a.from, 'from', ReplicaSide.a)
          .having((a) => a.bytes, 'bytes', 5),
    );
    expect(a.proposal.reverseBytes, 4);
    expect(a.choice, ActionChoice.proposed);
    expect(b.proposal.action, isA<DeleteAction>());
    expect(b.proposal.reverseBytes, isNull);
    expect(b.choice, ActionChoice.skipped);
    final conflict = read.conflicts.single;
    expect(
      conflict.conflict.a,
      isA<StatusModified>().having((s) => s.file.size, 'size', 3),
    );
    expect(conflict.conflict.b, isA<StatusDeleted>());
    expect(conflict.offered, [
      ConflictChoice.unresolved,
      ConflictChoice.keepA,
      ConflictChoice.keepB,
    ]);
    expect(conflict.choice, ConflictChoice.keepB);
  });

  test('a copy aside in an outcome reads with the path it wrote', () {
    final read = link.runView(
      runView(
        conflicts: [
          conflictRow(
            'd/x.txt',
            a: modifiedFile(),
            b: modifiedFile(),
            outcome: outcome(
              copyAside(
                'd/x.txt',
                to: 'd/x.dsync-copy-from-phone-2026-09-25-1200.txt',
                bytes: 7,
              ),
            ),
          ),
        ],
      ),
    );
    final result = read.conflicts.single.outcome!;
    expect(
      result.action,
      isA<CopyAsideAction>()
          .having((a) => a.path, 'path', 'd/x.txt')
          .having((a) => a.from, 'from', ReplicaSide.b)
          .having(
            (a) => a.to,
            'to',
            'd/x.dsync-copy-from-phone-2026-09-25-1200.txt',
          )
          .having((a) => a.bytes, 'bytes', 7),
    );
    expect(result.failure, isNull);
  });

  test('each phase reads as its own, with what it carries', () {
    RunPhase phase(wire.RunPhaseView phase) =>
        link.runView(runView(phase: phase)).phase;

    expect(
      phase(reviewing(apply: 3, reversed: 1, leftOpen: 2)),
      isA<RunReviewing>()
          .having((r) => r.summary.apply, 'apply', 3)
          .having((r) => r.summary.reversed, 'reversed', 1)
          .having((r) => r.summary.leftOpen, 'left open', 2),
    );
    final guard = phase(confirmingDeletes()) as RunConfirmingDeletes;
    final side = guard.sides.single;
    expect((side.side, side.deletes, side.archived), (ReplicaSide.b, 40, 50));
    expect(
      phase(finished(applied: 1, skipped: 2)),
      isA<RunFinished>()
          .having((f) => f.summary.applied, 'applied', 1)
          .having((f) => f.summary.skipped, 'skipped', 2),
    );
    expect((phase(stopped(4)) as RunStopped).completed, 4);
    expect((phase(paused(2)) as RunPaused).completed, 2);
    expect((phase(failedWith('no')) as RunFailed).message, 'no');
    expect((phase(replicaBusy('held')) as RunReplicaBusy).message, 'held');
    expect(
      phase(const wire.RunPhaseViewDeletesDeclined()),
      isA<RunDeletesDeclined>(),
    );
    expect(phase(const wire.RunPhaseViewNoSummary()), isA<RunNoSummary>());
  });

  test('the header\'s facts, the progress and the timings read as sent', () {
    final at = DateTime(2026, 9, 16, 12);
    final read = link.runView(
      runView(
        connectedAt: at,
        replicas: replicas(lastA: at),
        progress: (completed: 3, total: 9),
        applied: 2,
        failed: 1,
        timings: 'run: 1s',
      ),
    );
    expect(read.connectedAt, at);
    expect(read.replicas!.a.lastCommit, at);
    expect(read.replicas!.b.lastCommit, isNull);
    expect(read.progress, (completed: 3, total: 9));
    expect((read.applied, read.failed), (2, 1));
    expect(read.timings, 'run: 1s');
  });

  test('an intent is written as the hub reads it', () {
    expect(
      link.wireIntent(const ChooseAction(2, ActionChoice.reversed)),
      const wire.RunIntentChooseAction(
        index: 2,
        choice: wire.ActionChoiceView.reversed,
      ),
    );
    expect(
      link.wireIntent(const ChooseConflict(1, ConflictChoice.keepBoth)),
      const wire.RunIntentChooseConflict(
        index: 1,
        choice: wire.ConflictChoiceView.keepBoth,
      ),
    );
    expect(
      link.wireIntent(const AnswerDeletes(proceed: false)),
      const wire.RunIntentAnswerDeletes(proceed: false),
    );
    expect(link.wireIntent(const CloseRun()), const wire.RunIntentClose());
  });
}
