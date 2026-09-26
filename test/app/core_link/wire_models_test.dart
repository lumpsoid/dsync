import 'package:dsync/app/core_link/models/conflict_resolution.dart';
import 'package:dsync/app/core_link/models/file_status.dart';
import 'package:dsync/app/core_link/models/plan_action.dart';
import 'package:dsync/app/core_link/models/replica_side.dart';
import 'package:dsync/app/core_link/models/run_decision.dart';
import 'package:dsync/app/core_link/models/run_end.dart';
import 'package:dsync/app/core_link/models/run_update.dart';
import 'package:dsync/app/core_link/wire_models.dart';
import 'package:dsync/app/rust/bindings/bindings.dart' as wire;
import 'package:flutter_test/flutter_test.dart';

/// The generated signal classes read as the head's models, and the head's
/// decision written back: plain values both ways, no native library.
void main() {
  wire.Uint64 n(int value) => wireId(value);

  test('a plan reads with its proposals, conflicts and sizes', () {
    final plan = runUpdate(
      wire.RunUpdateBodyPlan(
        actions: [
          wire.ProposalView(
            action: wire.ActionViewCopy(
              path: 'a.txt',
              from: wire.SideView.a,
              bytes: n(5),
            ),
            reverseBytes: n(4),
          ),
          const wire.ProposalView(
            action: wire.ActionViewDelete(path: 'b.txt', on: wire.SideView.b),
            reverseBytes: null,
          ),
        ],
        conflicts: [
          wire.ConflictView(
            path: 'c.txt',
            a: wire.StatusViewModified(
              value: wire.FileView(size: n(3), mtimeUs: 9),
            ),
            b: const wire.StatusViewDeleted(),
            interrupted: false,
          ),
        ],
        bytesToTransfer: n(5),
        exceedsWarnSize: false,
        awaitingDecision: true,
      ),
    );
    expect(plan, isA<RunPlan>());
    final RunPlan(:actions, :conflicts, :bytesToTransfer) = plan as RunPlan;
    expect(bytesToTransfer, 5);
    expect(
      actions.first.action,
      isA<CopyAction>()
          .having((a) => a.from, 'from', ReplicaSide.a)
          .having((a) => a.bytes, 'bytes', 5),
    );
    expect(actions.first.reverseBytes, 4);
    expect(actions.last.action, isA<DeleteAction>());
    expect(actions.last.reverseBytes, isNull);
    expect(
      conflicts.single.a,
      isA<StatusModified>().having((s) => s.file.size, 'size', 3),
    );
    expect(conflicts.single.b, isA<StatusDeleted>());
  });

  test('a copy aside in a result reads with the path it wrote', () {
    final applied = runUpdate(
      wire.RunUpdateBodyApplied(
        approved: const [],
        results: [
          wire.ResultView(
            action: wire.ActionViewCopyAside(
              path: 'd/x.txt',
              from: wire.SideView.b,
              to: 'd/x.dsync-copy-from-phone-2026-09-25-1200.txt',
              bytes: n(7),
            ),
          ),
        ],
      ),
    );
    final RunApplied(:results) = applied as RunApplied;
    expect(
      results.single.action,
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
    expect(results.single.failure, isNull);
  });

  test('a run that ran reads with its summary and how it stopped', () {
    final ended = runUpdate(
      wire.RunUpdateBodyEnded(
        value: wire.RunEndViewRan(
          summary: wire.SummaryView(
            applied: n(1),
            skipped: n(2),
            conflicts: n(0),
            failed: n(0),
            unreadable: n(0),
          ),
          errored: false,
          stopped: wire.StoppedView.gracefully,
          timings: 'run: 1s',
        ),
      ),
    );
    final end = (ended as RunEnded).end as RunRan;
    expect(end.summary?.applied, 1);
    expect(end.stopped, StopKind.gracefully);
  });

  test('a mass delete reads per side, with whether it waits on the head', () {
    final guard = runUpdate(
      wire.RunUpdateBodyMassDelete(
        sides: [
          wire.MassDeleteView(
            side: wire.SideView.b,
            deletes: n(40),
            archived: n(50),
          ),
        ],
        awaitingConfirmation: true,
      ),
    );
    final massDelete = guard as RunMassDelete;
    expect(massDelete.awaitingConfirmation, isTrue);
    final side = massDelete.sides.single;
    expect((side.side, side.deletes, side.archived), (ReplicaSide.b, 40, 50));
  });

  test('a decision is written as indices, reversals and resolutions', () {
    final written = wireDecision(
      const RunDecision(
        keep: [(index: 0, reversed: false), (index: 2, reversed: true)],
        resolve: {1: KeepSide(ReplicaSide.b), 3: KeepBoth()},
      ),
    );
    expect(
      [for (final kept in written.keep) (kept.index, kept.reversed)],
      [(0, false), (2, true)],
    );
    expect([for (final choice in written.resolve) choice.conflict], [1, 3]);
    expect(
      written.resolve[0].resolution,
      isA<wire.ConflictResolutionViewKeep>().having(
        (keep) => keep.value,
        'side',
        wire.SideView.b,
      ),
    );
    expect(
      written.resolve[1].resolution,
      isA<wire.ConflictResolutionViewKeepBoth>(),
    );
  });
}
