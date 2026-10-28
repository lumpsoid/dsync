import 'dart:async';

import 'package:dsync/app/core_link/models/compared_side.dart';
import 'package:dsync/app/core_link/models/replica_side.dart';
import 'package:dsync/app/core_link/models/row_ref.dart';
import 'package:dsync/app/features/file_diff/file_diff_controller.dart';
import 'package:dsync/app/features/file_diff/file_diff_view_state.dart';
import 'package:dsync/app/rust/bindings/bindings.dart' as wire;
import 'package:test/test.dart';

import '../../support/fake_hub.dart';
import '../../support/fake_head.dart';

/// Covers `FileDiffController` over a [FakeHub]: one read shows its
/// reading line then the comparison, a stale read is dropped, and leaving
/// mid-read cancels the compare the core is still answering.
void main() {
  FileDiffArgs args(RowRef row, {String path = 'notes.txt'}) => FileDiffArgs(
    session: 7,
    row: row,
    path: path,
    oldSide: const ComparedSide(ReplicaSide.a, 10),
    newSide: const ComparedSide(ReplicaSide.b, 2048),
  );

  /// The request id of every `CompareRow` sent, in order.
  List<int> compareIds(FakeHub hub) => [
    for (final request in hub.requests)
      if (request.command is wire.CoreCommandCompareRow) request.id.toInt(),
  ];

  /// Lets the fake hub's replies, and the link's handling of them, run.
  Future<void> drain() => Future<void>.delayed(Duration.zero);

  test('a read shows its reading line, then the comparison', () async {
    final gate = Completer<void>();
    final hub = FakeHub()
      ..hold<wire.CoreCommandCompareRow>(gate.future)
      ..reply<wire.CoreCommandCompareRow>(
        const wire.ReplyResultComparison(
          value: wire.ComparisonViewNotComparable(),
        ),
      );
    final controller = FileDiffController(fakeApp(hub));
    addTearDown(controller.dispose);

    final read = controller.open(args(const ConflictRowRef(3)));
    expect(
      (controller.state.view as FileDiffReading).line,
      'Reading Remote · 2.0 KiB…',
    );
    expect(controller.state.path, 'notes.txt');
    final [compare] = hub.sent<wire.CoreCommandCompareRow>();
    expect(compare.session.toInt(), 7);
    expect(compare.row, isA<wire.RowRefConflict>());

    gate.complete();
    await read;
    expect(
      (controller.state.view as FileDiffSentence).sentence,
      'Nothing to compare for this row',
    );
  });

  test('a failed read shows the failure', () async {
    final hub = FakeHub()
      ..reply<wire.CoreCommandCompareRow>(
        const wire.ReplyResultFailed(message: 'the review is no longer open'),
      );
    final controller = FileDiffController(fakeApp(hub));
    addTearDown(controller.dispose);

    await controller.open(args(const ActionRowRef(0)));
    expect(
      (controller.state.view as FileDiffFailed).message,
      'the review is no longer open',
    );
  });

  test('a read that lands after a newer one started is dropped', () async {
    final slow = Completer<void>();
    final hub = FakeHub()
      ..hold<wire.CoreCommandCompareRow>(slow.future)
      ..answer<wire.CoreCommandCompareRow>(
        (compare) => wire.ReplyResultComparison(
          value: compare.row is wire.RowRefConflict
              ? const wire.ComparisonViewNotComparable()
              : const wire.ComparisonViewCompared(
                  path: 'old.txt',
                  oldSide: wire.SidedView(side: wire.SideView.a, size: null),
                  newSide: wire.SidedView(side: wire.SideView.b, size: null),
                  verdict: wire.ComparedViewMedia(),
                ),
        ),
      );
    final controller = FileDiffController(fakeApp(hub));
    addTearDown(controller.dispose);

    final first = controller.open(args(const ActionRowRef(0)));
    hub.hold<wire.CoreCommandCompareRow>(Future<void>.value());
    await controller.open(args(const ConflictRowRef(0), path: 'new.txt'));
    expect(
      (controller.state.view as FileDiffSentence).sentence,
      'Nothing to compare for this row',
    );

    slow.complete();
    await first;
    // The stale read was answered — a media verdict, which is what shows
    // here if the generation check is removed — and dropped.
    expect(compareIds(hub), hasLength(2));
    expect(
      (controller.state.view as FileDiffSentence).sentence,
      'Nothing to compare for this row',
    );
    expect(controller.state.path, 'new.txt');
  });

  test('leaving mid-read cancels the compare by its request id', () async {
    final hub = FakeHub()..holdCompareUntilCancelled();
    final controller = FileDiffController(fakeApp(hub));

    final read = controller.open(args(const ActionRowRef(1)));
    await drain();
    controller.dispose();
    await read;

    expect(hub.cancelledCompares, compareIds(hub));
    expect(hub.cancelledCompares, hasLength(1));
    final cancel = hub.sent<wire.CoreCommandCancelCompare>().single;
    expect(cancel.session.toInt(), 7);
  });

  test('leaving after the reply cancels nothing', () async {
    final hub = FakeHub()
      ..reply<wire.CoreCommandCompareRow>(
        const wire.ReplyResultComparison(
          value: wire.ComparisonViewNotComparable(),
        ),
      );
    final controller = FileDiffController(fakeApp(hub));

    await controller.open(args(const ActionRowRef(1)));
    controller.dispose();
    await drain();

    expect(compareIds(hub), hasLength(1));
    expect(hub.sent<wire.CoreCommandCancelCompare>(), isEmpty);
  });
}
