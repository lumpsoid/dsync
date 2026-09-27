import 'package:dsync/app/rust/bindings/bindings.dart' as wire;
import 'package:test/test.dart';

import '../features/run/run_fixtures.dart';
import 'fake_hub.dart';

/// `FakeHub.emitRun` sends a run view's plan as the hub does: whole the
/// first time, then only the rows whose choice or outcome changed.
void main() {
  late FakeHub hub;
  late List<wire.PlanUpdateView> sent;

  setUp(() {
    hub = FakeHub();
    sent = [];
    hub.runSnapshots.listen((snapshot) => sent.add(snapshot.view.plan));
  });

  /// What the head receives as [view]'s plan in [session].
  wire.PlanUpdateView emit(WholeRunView view, {int session = 1}) {
    hub.emitRun(session, view, last: false);
    return sent.last;
  }

  final rows = [planRow(copyTo('a.txt')), planRow(deleteThere('b.txt'))];
  final conflicts = [conflictRow('c.txt', offered: offersAll)];
  WholeRunView view({
    List<wire.PlanRowView>? plan,
    List<wire.ConflictRowView>? conflictRows,
    int bytesToTransfer = 0,
  }) => runView(
    plan: plan ?? rows,
    conflicts: conflictRows ?? conflicts,
    bytesToTransfer: bytesToTransfer,
  );

  const noChange = wire.PlanUpdateViewSame(actions: [], conflicts: []);

  test('the first plan goes whole', () {
    expect(emit(view()), wire.PlanUpdateViewNew(value: view().plan));
  });

  test('the same plan again goes as no rows changed', () {
    emit(view());
    expect(emit(view()), noChange);
  });

  test('an action\'s new outcome goes as that row alone', () {
    emit(view());
    final done = outcome(copyTo('a.txt'));
    expect(
      emit(
        view(
          plan: [
            planRow(copyTo('a.txt'), outcome: done),
            rows[1],
          ],
        ),
      ),
      wire.PlanUpdateViewSame(
        actions: [
          wire.ActionRowUpdateView(
            index: 0,
            choice: wire.ActionChoiceView.proposed,
            outcome: done,
          ),
        ],
        conflicts: const [],
      ),
    );
  });

  test('an action\'s new choice goes as that row alone', () {
    emit(view());
    expect(
      emit(
        view(
          plan: [
            rows[0],
            planRow(
              deleteThere('b.txt'),
              choice: wire.ActionChoiceView.skipped,
            ),
          ],
        ),
      ),
      const wire.PlanUpdateViewSame(
        actions: [
          wire.ActionRowUpdateView(
            index: 1,
            choice: wire.ActionChoiceView.skipped,
            outcome: null,
          ),
        ],
        conflicts: [],
      ),
    );
  });

  test('a conflict\'s new choice goes as that row alone', () {
    emit(view());
    expect(
      emit(
        view(
          conflictRows: [
            conflictRow(
              'c.txt',
              offered: offersAll,
              choice: wire.ConflictChoiceView.keepB,
            ),
          ],
        ),
      ),
      const wire.PlanUpdateViewSame(
        actions: [],
        conflicts: [
          wire.ConflictRowUpdateView(
            index: 0,
            choice: wire.ConflictChoiceView.keepB,
            outcome: null,
          ),
        ],
      ),
    );
  });

  test('a conflict\'s new outcome goes as that row alone', () {
    emit(view());
    final done = outcome(copyTo('c.txt'), failure: 'gone');
    expect(
      emit(
        view(
          conflictRows: [
            conflictRow('c.txt', offered: offersAll, outcome: done),
          ],
        ),
      ),
      wire.PlanUpdateViewSame(
        actions: const [],
        conflicts: [
          wire.ConflictRowUpdateView(
            index: 0,
            choice: wire.ConflictChoiceView.unresolved,
            outcome: done,
          ),
        ],
      ),
    );
  });

  test('no plan rows go as absent, and the next plan goes whole again', () {
    emit(view());
    expect(
      emit(view(plan: [], conflictRows: [])),
      isA<wire.PlanUpdateViewAbsent>(),
    );
    expect(emit(view()), wire.PlanUpdateViewNew(value: view().plan));
  });

  test('other proposals, offers or sizes go as a new plan', () {
    emit(view());
    final moved = view(plan: [planRow(copyTo('z.txt')), rows[1]]);
    expect(emit(moved), wire.PlanUpdateViewNew(value: moved.plan));

    emit(view());
    final offers = view(conflictRows: [conflictRow('c.txt')]);
    expect(emit(offers), wire.PlanUpdateViewNew(value: offers.plan));

    emit(view());
    final bigger = view(bytesToTransfer: 9);
    expect(emit(bigger), wire.PlanUpdateViewNew(value: bigger.plan));
  });

  test('each session remembers its own plan', () {
    emit(view());
    expect(emit(view(), session: 2), isA<wire.PlanUpdateViewNew>());
    expect(emit(view()), noChange);
  });
}
