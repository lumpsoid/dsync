import 'package:dsync/cli/presenter/dry_run_presenter.dart';
import 'package:dsync/dsync_core/models/plan.dart';
import 'package:dsync/dsync_core/models/scan_entry.dart';
import 'package:test/test.dart';

void main() {
  group('DryRunPresenter', () {
    test(
      'returns nothing even when the plan has actions and conflicts',
      () async {
        const plan = Plan(
          actions: [PlanAction(path: 'a.txt', type: ActionType.copyAtoB)],
          conflicts: [
            Conflict(
              path: 'c.txt',
              onA: ScanEntry(path: 'c.txt', reason: ScanReason.modified),
              onB: ScanEntry(path: 'c.txt', reason: ScanReason.modified),
            ),
          ],
        );

        final result = await const DryRunPresenter().call(plan);

        expect(result, isEmpty);
      },
    );

    test('returns nothing for an empty plan', () async {
      const plan = Plan(actions: [], conflicts: []);

      final result = await const DryRunPresenter().call(plan);

      expect(result, isEmpty);
    });
  });
}
