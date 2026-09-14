import 'package:dsync/cli/presenter/batch_presenter.dart';
import 'package:dsync/dsync_core/models/plan.dart';
import 'package:dsync/dsync_core/models/scan_entry.dart';
import 'package:test/test.dart';

void main() {
  group('BatchPresenter', () {
    test('returns plan.actions unchanged', () async {
      const actions = [
        PlanAction(path: 'a.txt', type: ActionType.copyAtoB, bytes: 10),
        PlanAction(path: 'b.txt', type: ActionType.deleteOnB),
      ];
      const plan = Plan(actions: actions, conflicts: []);

      final result = await const BatchPresenter().call(plan);

      expect(result, same(actions));
    });

    test('never resolves a conflict: conflicts are simply absent', () async {
      const plan = Plan(
        actions: [PlanAction(path: 'kept.txt', type: ActionType.copyAtoB)],
        conflicts: [
          Conflict(
            path: 'conflicted.txt',
            onA: ScanEntry(path: 'conflicted.txt', reason: ScanReason.modified),
            onB: ScanEntry(path: 'conflicted.txt', reason: ScanReason.modified),
          ),
        ],
      );

      final result = await const BatchPresenter().call(plan);

      expect(result.map((a) => a.path), ['kept.txt']);
    });
  });
}
