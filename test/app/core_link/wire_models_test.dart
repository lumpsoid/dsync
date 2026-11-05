import 'package:dsync/app/core_link/models/action_choice.dart';
import 'package:dsync/app/core_link/models/compare_offer.dart';
import 'package:dsync/app/core_link/models/conflict_choice.dart';
import 'package:dsync/app/core_link/models/entry_run_status.dart';
import 'package:dsync/app/core_link/models/file_status.dart';
import 'package:dsync/app/core_link/models/plan_action.dart';
import 'package:dsync/app/core_link/models/replica_side.dart';
import 'package:dsync/app/core_link/models/root_kind.dart';
import 'package:dsync/app/core_link/models/run_intent.dart';
import 'package:dsync/app/core_link/models/run_phase.dart';
import 'package:dsync/app/core_link/models/run_plan.dart';
import 'package:dsync/app/core_link/models/run_plan_update.dart';
import 'package:dsync/app/core_link/models/run_standing.dart';
import 'package:dsync/app/core_link/models/run_view.dart';
import 'package:dsync/app/core_link/models/sync_history.dart';
import 'package:dsync/app/core_link/wire_models.dart' as link;
import 'package:dsync/app/rust/bindings/bindings.dart' as wire;
import 'package:flutter_test/flutter_test.dart';

import '../features/run/run_fixtures.dart';
import '../support/fake_hub.dart';

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
      bytesToTransfer: 5,
    );

    final read = planOf(decode(view));
    expect(read.bytesToTransfer, 5);
    final [a, b] = read.actions;
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

  test('each offer reads onto a plan row and a conflict row', () {
    final offers = <wire.OfferView>[
      wire.OfferViewNotComparable(),
      wire.OfferViewReadable(),
      wire.OfferViewMedia(),
      wire.OfferViewTooLarge(side: wire.SideView.b, size: n(99)),
    ];
    final read = planOf(
      decode(
        runView(
          plan: [
            for (final (i, offer) in offers.indexed)
              planRow(copyTo('p$i.txt', bytes: 1), offer: offer),
          ],
          conflicts: [
            for (final (i, offer) in offers.indexed)
              conflictRow(
                'c$i.txt',
                a: modifiedFile(),
                b: modifiedFile(),
                offer: offer,
              ),
          ],
        ),
      ),
    );
    final planned = [for (final row in read.actions) row.proposal.offer];
    final conflicted = [for (final row in read.conflicts) row.offer];
    for (final read in [planned, conflicted]) {
      expect(read[0], isA<OfferNotComparable>());
      expect(read[1], isA<OfferReadable>());
      expect(read[2], isA<OfferMedia>());
      expect(
        read[3],
        isA<OfferTooLarge>()
            .having((o) => o.side, 'side', ReplicaSide.b)
            .having((o) => o.size, 'size', 99),
      );
    }
  });

  test('a copy aside in an outcome reads with the path it wrote', () {
    final read = decode(
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
    final result = planOf(read).conflicts.single.outcome!;
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
        decode(runView(phase: phase)).phase;

    expect(
      phase(reviewing(planId: 7, apply: 3, reversed: 1, leftOpen: 2)),
      isA<RunReviewing>()
          .having((r) => r.planId, 'plan', 7)
          .having((r) => r.summary.apply, 'apply', 3)
          .having((r) => r.summary.reversed, 'reversed', 1)
          .having((r) => r.summary.leftOpen, 'left open', 2),
    );
    final guard = phase(confirmingDeletes(planId: 8)) as RunConfirmingDeletes;
    expect(guard.planId, 8);
    final side = guard.sides.single;
    expect((side.side, side.deletes, side.archived), (ReplicaSide.b, 40, 50));
    final overwrites = phase(
      confirmingOverwrites(planId: 9, truncated: 3),
    ) as RunConfirmingOverwrites;
    expect(overwrites.planId, 9);
    final rewritten = overwrites.sides.single;
    expect(
      (
        rewritten.side,
        rewritten.overwrites,
        rewritten.truncated,
        rewritten.archived,
      ),
      (ReplicaSide.b, 40, 3, 50),
    );
    expect(
      phase(const wire.RunPhaseViewOverwritesDeclined()),
      isA<RunOverwritesDeclined>(),
    );
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
    final issues =
        phase(finishedWithIssues(1, 'not run')) as RunFinishedWithIssues;
    expect(
      (issues.entries.single.index, issues.entries.single.reason),
      (1, 'not run'),
    );
  });

  test('a session\'s entries read with their roots, statuses and the one '
      'running', () {
    final read = decode(
      runView(
        entries: [
          entryRun(status: const wire.EntryStatusViewSkipped(reason: 'gone')),
          entryRun(
            kind: wire.RootKindView.file,
            local: '/data/todo.md',
            remote: '~/todo.md',
          ),
          entryRun(status: const wire.EntryStatusViewPending()),
        ],
        current: 1,
      ),
    );

    expect(read.current, 1);
    expect(
      [for (final entry in read.entries) entry.status],
      [
        isA<EntrySkipped>().having((s) => s.reason, 'reason', 'gone'),
        isA<EntryRunning>(),
        isA<EntryPending>(),
      ],
    );
    final file = read.entries[1];
    expect(
      (file.kind, file.localRoot, file.remoteRoot),
      (RootKind.file, '/data/todo.md', '~/todo.md'),
    );
  });

  test('the header\'s facts, the progress and the timings read as sent', () {
    final at = DateTime(2026, 9, 16, 12);
    final read = decode(
      runView(
        connectedAt: at,
        replicas: replicas(lastA: at),
        progress: (completed: 3, received: 3, total: 9),
        applied: 2,
        failed: 1,
        timings: 'run: 1s',
      ),
    );
    expect(read.connectedAt, at);
    expect(read.replicas!.a.lastCommit, at);
    expect(read.replicas!.b.lastCommit, isNull);
    expect(read.progress, (completed: 3, received: 3, total: 9));
    expect((read.applied, read.failed), (2, 1));
    expect(read.timings, 'run: 1s');
  });

  test('the core\'s verdicts read as sent: standing, history, totals and '
      'the plan\'s bytes', () {
    final at = DateTime(2026, 9, 16, 12);
    final read = decode(
      runView(
        phase: paused(1),
        standing: resumable,
        replicas: replicas(lastA: at, history: oneSided(wire.SideView.b)),
        tallies: tallies(
          b: tally(modified: 4, total: 14, changed: 5),
          checked: 25,
          changed: 7,
        ),
        plan: [
          planRow(copyTo('up.txt', bytes: 10)),
          planRow(copyHere('down.txt', bytes: 3)),
        ],
        bytesToA: 3,
        bytesToB: 10,
      ),
    );
    expect(read.standing, RunStanding.resumable);
    expect(
      read.replicas!.history,
      isA<OneSidedFirstSync>().having((h) => h.empty, 'empty', ReplicaSide.b),
    );
    expect((read.tallies!.a.total, read.tallies!.b.changed), (11, 5));
    expect((read.tallies!.checked, read.tallies!.changed), (25, 7));
    expect(planOf(read).summary, (bytesToA: 3, bytesToB: 10));
    expect(
      decode(
        runView(
          replicas: replicas(lastA: at, lastB: at, history: synced(at, at)),
        ),
      ).replicas!.history,
      isA<LastSynced>().having((h) => h.b, 'b', at),
    );
  });

  test('a view with no plan reads as absent', () {
    expect(decode(runView()).plan, isA<RunPlanAbsent>());
  });

  test('a view naming its changed rows reads each with its index, choice '
      'and outcome', () {
    final read = link.runView(
      runView().withPlan(
        wire.PlanUpdateViewSame(
          actions: [
            wire.ActionRowUpdateView(
              index: 3,
              choice: wire.ActionChoiceView.skipped,
              outcome: outcome(copyTo('a.txt'), failure: 'disk full'),
            ),
          ],
          conflicts: const [
            wire.ConflictRowUpdateView(
              index: 1,
              choice: wire.ConflictChoiceView.keepA,
              outcome: null,
            ),
          ],
        ),
      ),
    );

    final same = read.plan as RunPlanSame;
    final action = same.actions.single;
    expect((action.index, action.choice), (3, ActionChoice.skipped));
    expect(action.outcome!.action, isA<CopyAction>());
    expect(action.outcome!.failure, 'disk full');
    final conflict = same.conflicts.single;
    expect(
      (conflict.index, conflict.choice, conflict.outcome),
      (1, ConflictChoice.keepA, null),
    );
    expect(
      link
          .runView(
            runView().withPlan(
              const wire.PlanUpdateViewSame(actions: [], conflicts: []),
            ),
          )
          .plan,
      isA<RunPlanSame>()
          .having((s) => s.actions, 'actions', isEmpty)
          .having((s) => s.conflicts, 'conflicts', isEmpty),
    );
  });

  test('an intent is written as the hub reads it', () {
    expect(
      link.wireIntent(const ChooseAction(2, ActionChoice.reversed, planId: 4)),
      wire.RunIntentChooseAction(
        planId: n(4),
        index: 2,
        choice: wire.ActionChoiceView.reversed,
      ),
    );
    expect(
      link.wireIntent(
        const ChooseConflict(1, ConflictChoice.keepBoth, planId: 4),
      ),
      wire.RunIntentChooseConflict(
        planId: n(4),
        index: 1,
        choice: wire.ConflictChoiceView.keepBoth,
      ),
    );
    expect(
      link.wireIntent(const ConfirmReview(planId: 5)),
      wire.RunIntentConfirm(planId: n(5)),
    );
    expect(
      link.wireIntent(const AcceptAll(planId: 5)),
      wire.RunIntentAcceptAll(planId: n(5)),
    );
    expect(
      link.wireIntent(const AnswerDeletes(planId: 6, proceed: false)),
      wire.RunIntentAnswerDeletes(planId: n(6), proceed: false),
    );
    expect(
      link.wireIntent(const AnswerOverwrites(planId: 6, proceed: true)),
      wire.RunIntentAnswerOverwrites(planId: n(6), proceed: true),
    );
    expect(link.wireIntent(const CloseRun()), const wire.RunIntentClose());
  });
}

/// [view] as the first the head receives: its plan whole, or absent.
RunView decode(WholeRunView view) =>
    link.runView(view.withPlan(planUpdate(null, view.plan)));

/// The plan [view] carries whole.
RunPlan planOf(RunView view) => switch (view.plan) {
  RunPlanNew(:final plan) => plan,
  final other => throw StateError('no whole plan: $other'),
};
