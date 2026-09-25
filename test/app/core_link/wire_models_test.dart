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

  test('a plan reads with its actions, conflicts and sizes', () {
    final plan = runUpdate(
      wire.RunUpdateBodyPlan(
        actions: [
          wire.ActionViewCopy(
            path: 'a.txt',
            from: wire.SideView.a,
            bytes: n(5),
          ),
          const wire.ActionViewDelete(path: 'b.txt', on: wire.SideView.b),
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
      actions.first,
      isA<CopyAction>()
          .having((a) => a.from, 'from', ReplicaSide.a)
          .having((a) => a.bytes, 'bytes', 5),
    );
    expect(actions.last, isA<DeleteAction>());
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

  test('a decision is written as indices and sides', () {
    final written = wireDecision(
      const RunDecision(keep: [0, 2], resolve: {1: ReplicaSide.b}),
    );
    expect(written.keep, [0, 2]);
    expect(written.resolve.single.conflict, 1);
    expect(written.resolve.single.keep, wire.SideView.b);
  });
}
