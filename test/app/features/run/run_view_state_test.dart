import 'package:dsync/app/core_link/models/action_choice.dart';
import 'package:dsync/app/core_link/models/conflict_choice.dart';
import 'package:dsync/app/features/run/run_controller.dart';
import 'package:dsync/app/features/run/run_view_state.dart';
import 'package:dsync/app/rust/bindings/bindings.dart' as wire;
import 'package:test/test.dart';

import 'run_fixtures.dart';

/// `SyncRunViewState` as the core's views of a run render into it, played
/// by a `FakeHub` — no core, no sockets, no widgets. Every test here is
/// "given this view, the page's values are these": the wording, and which
/// of the page's listenables a view wakes. What the run decides is the
/// core's (native/hub).
void main() {
  final now = DateTime(2026, 9, 16, 12, 0);
  late RunHarness harness;

  SyncRunViewState state() => harness.state;

  /// The rendered plan row for [path].
  SyncRunPlanRow planRowAt(String path) =>
      state().plan.singleWhere((row) => row.path == path);

  /// The rendered conflict row for [path].
  SyncRunConflictRow conflictAt(String path) =>
      state().conflicts.singleWhere((row) => row.path == path);

  setUp(() async {
    harness = RunHarness(now: () => now);
    await harness.start();
  });
  tearDown(() => harness.dispose());

  final happy = runView(
    phase: applying,
    connectedAt: now,
    replicas: replicas(
      lastA: now.subtract(const Duration(hours: 2)),
      lastB: now.subtract(const Duration(hours: 2)),
    ),
    tallies: tallies(),
    skipped: [
      skippedPath(
        side: wire.SideView.a,
        path: 'link',
        reason: wire.SkippedReasonView.symlink,
        detail: 'no follow rule matched',
        isFailure: false,
      ),
      skippedPath(
        side: wire.SideView.b,
        path: 'locked.txt',
        reason: wire.SkippedReasonView.unreadable,
        detail: 'Permission denied',
        isFailure: true,
      ),
    ],
    conflicts: [conflictRow('both.txt', a: createdFile(), b: modifiedFile())],
    plan: [
      planRow(copyTo('new.txt'), outcome: outcome(copyTo('new.txt'))),
      planRow(
        deleteHere('gone.txt'),
        outcome: outcome(deleteHere('gone.txt'), failure: 'Permission denied'),
      ),
    ],
    progress: (completed: 2, total: 2),
    applied: 1,
    failed: 1,
  );

  group('the core\'s view, rendered', () {
    test('header: both locations and the last sync', () async {
      await harness.show(happy);

      final header = state().header!;
      expect(header.localRoot, '/data/notes');
      expect(header.remoteRoot, '~/notes');
      expect(header.history, contains('Last synced'));
      expect(header.history, contains('2 hour(s) ago'));
      expect(header.firstSyncWarning, isNull);
    });

    test(
      'scan tally: metadata-matched and hash-matched both surface',
      () async {
        await harness.show(happy);

        final tally = state().scanTally!;
        expect(tally.local.metadataMatched, 7);
        expect(tally.local.hashMatched, 2);
        expect(tally.remote.metadataMatched, 7);
        expect(tally.remote.hashMatched, 2);
        expect(tally.local.total, 11);
      },
    );

    test('skipped symlinks and unreadable paths are two lists', () async {
      await harness.show(happy);

      expect(state().skippedSymlinks, hasLength(1));
      expect(
        state().skippedSymlinks.single,
        allOf(contains('link'), contains('this device'), contains('no follow')),
      );
      expect(state().unreadablePaths, hasLength(1));
      expect(
        state().unreadablePaths.single,
        allOf(
          contains('locked.txt'),
          contains('remote'),
          contains('Permission'),
        ),
      );
    });

    test(
      'a case-fold collision is a failure, so it lists as unreadable',
      () async {
        await harness.show(
          runView(
            skipped: [
              skippedPath(
                side: wire.SideView.a,
                path: 'A.txt',
                reason: wire.SkippedReasonView.caseFoldCollision,
                detail: 'collides with a.txt',
                isFailure: true,
              ),
            ],
          ),
        );

        expect(state().unreadablePaths.single, contains('A.txt'));
        expect(state().skippedSymlinks, isEmpty);
      },
    );

    test('conflicts: each side as a status, no record as none, and what '
        'the core offers', () async {
      await harness.show(happy);

      final row = state().conflicts.single;
      expect(row.index, 0);
      expect(row.path, 'both.txt');
      expect(row.local.status, SyncRunSideStatus.created);
      expect(row.remote.status, SyncRunSideStatus.modified);
      expect(row.offered, [
        ConflictChoice.unresolved,
        ConflictChoice.keepA,
        ConflictChoice.keepB,
        ConflictChoice.keepBoth,
      ]);

      await harness.show(
        runView(conflicts: [conflictRow('only.txt', a: createdFile())]),
      );
      final only = state().conflicts.single;
      expect(only.remote.status, SyncRunSideStatus.none);
      expect(only.remote.file, isNull);
      expect(only.offered, [ConflictChoice.unresolved, ConflictChoice.keepA]);
    });

    test('conflicts: a side with a file carries when it was modified and its '
        'size; a side without one carries neither', () async {
      final thisYear = DateTime(2026, 9, 15, 14, 3);
      final lastYear = DateTime(2025, 3, 2, 9, 7);
      wire.StatusView modifiedAt(DateTime at, int size) =>
          wire.StatusViewModified(
            value: wire.FileView(
              size: n(size),
              mtimeUs: at.microsecondsSinceEpoch,
            ),
          );
      await harness.show(
        runView(
          conflicts: [
            conflictRow(
              'both.txt',
              a: modifiedAt(thisYear, 12288),
              b: modifiedAt(lastYear, 5),
            ),
            conflictRow(
              'gone.txt',
              a: modifiedAt(thisYear, 1),
              b: const wire.StatusViewDeleted(),
            ),
          ],
        ),
      );

      final [both, gone] = state().conflicts;
      // This year's needs no year; last year's does. Local time, the
      // clock the reader reads.
      expect(both.local.file, (modified: '15 Sep 14:03', bytes: 12288));
      expect(both.remote.file, (modified: '2 Mar 2025 09:07', bytes: 5));
      expect(gone.remote.status, SyncRunSideStatus.deleted);
      expect(gone.remote.file, isNull);
    });

    test('plan: rows worded from this device, bytes summed', () async {
      await harness.show(happy);

      final plan = state().plan;
      expect(plan, hasLength(2));
      expect(plan[0].index, 0);
      expect(plan[0].path, 'new.txt');
      expect(plan[0].action, 'copy to the remote');
      expect(plan[0].bytes, 2048);
      expect(plan[0].group, SyncRunPlanGroup.toDevice);
      expect(plan[1].index, 1);
      expect(plan[1].action, 'delete on this device');
      expect(plan[1].group, SyncRunPlanGroup.deletions);
      expect(state().bytesToTransfer, 2048);
    });

    test('each group\'s index list and bytes are folded once: every group '
        'present, empty ones included', () async {
      await harness.show(happy);

      final sections = state().planSections;
      expect(sections.keys, containsAll(SyncRunPlanGroup.values));

      final toDevice = sections[SyncRunPlanGroup.toDevice]!;
      expect(toDevice.indexes, [0]);
      expect(toDevice.count, 1);
      expect(toDevice.bytes, 2048);

      final deletions = sections[SyncRunPlanGroup.deletions]!;
      expect(deletions.indexes, [1]);
      expect(deletions.count, 1);
      expect(deletions.bytes, 0);

      // Positive control: a group with nothing in it is still present,
      // as an empty section rather than absent from the map.
      final toThisDevice = sections[SyncRunPlanGroup.toThisDevice]!;
      expect(toThisDevice.indexes, isEmpty);
      expect(toThisDevice.count, 0);
      final recordOnly = sections[SyncRunPlanGroup.recordOnly]!;
      expect(recordOnly.indexes, isEmpty);
    });

    test(
      'a plan with one row per group sorts each into its own section',
      () async {
        await harness.show(
          runView(
            plan: [
              planRow(copyTo('to-device.txt', bytes: 10)),
              planRow(copyHere('to-this.txt', bytes: 20)),
              planRow(deleteHere('gone-a.txt')),
              planRow(deleteThere('gone-b.txt')),
              planRow(recordOnly('same.txt')),
            ],
          ),
        );

        final sections = state().planSections;
        expect(sections[SyncRunPlanGroup.toDevice]!.indexes, [0]);
        expect(sections[SyncRunPlanGroup.toThisDevice]!.indexes, [1]);
        // Deletions is one group for either side: both rows land in it.
        expect(sections[SyncRunPlanGroup.deletions]!.indexes, [2, 3]);
        expect(sections[SyncRunPlanGroup.recordOnly]!.indexes, [4]);
      },
    );

    test('a row the core offers a reverse for carries it, worded '
        'literally', () async {
      await harness.show(
        runView(
          plan: [
            planRow(copyTo('mine.txt'), reverseBytes: 1024),
            planRow(copyHere('theirs.txt'), reverseBytes: 64),
            planRow(deleteThere('gone.txt'), reverseBytes: 512),
            planRow(deleteHere('lost.txt'), reverseBytes: 8),
            planRow(copyTo('mirror.txt', bytes: 10)),
          ],
        ),
      );

      final [mine, theirs, gone, lost, mirror] = state().plan;
      expect(
        mine.reversal,
        const SyncRunPlanReversal(
          action: "replace this device's version with the remote's",
          bytes: 1024,
        ),
      );
      expect(
        theirs.reversal!.action,
        "replace the remote's version with this device's",
      );
      expect(gone.reversal!.action, 'restore on this device from the remote');
      expect(gone.reversal!.bytes, 512);
      expect(lost.reversal!.action, 'restore on the remote from this device');
      expect(mirror.reversal, isNull);
    });

    test('results, counts and progress are the view\'s', () async {
      await harness.show(happy);

      expect(state().resultCell('new.txt').value?.error, isNull);
      expect(state().resultCell('new.txt').value?.action, 'copy to the remote');
      expect(
        state().resultCell('gone.txt').value?.error,
        contains('Permission denied'),
      );
      expect(state().progress!.completed, 2);
      expect(state().progress!.total, 2);
      expect(state().appliedCount, 1);
      expect(state().failedCount, 1);
    });

    test(
      'a conflict\'s outcome is its row\'s, worded as what it did',
      () async {
        await harness.show(
          runView(
            conflicts: [
              conflictRow(
                'both.txt',
                a: modifiedFile(),
                b: modifiedFile(),
                choice: wire.ConflictChoiceView.keepBoth,
                outcome: outcome(
                  copyAside('both.txt', to: 'dir/both (desktop).txt'),
                ),
              ),
            ],
          ),
        );

        expect(
          state().resultCell('both.txt').value?.action,
          'saved the remote version as both (desktop).txt',
        );
        expect(
          state().conflictDecisionCell(conflictAt('both.txt')).value,
          ConflictChoice.keepBoth,
        );
      },
    );

    test('connecting stamps the start time the page shows', () async {
      await harness.show(runView(phase: scanning, connectedAt: now));

      expect(state().startedAt, '12:00');
    });

    test('summary: five numbers, skipped and unreadable kept apart', () async {
      await harness.show(
        runView(phase: finished(applied: 4, skipped: 3, unreadable: 2)),
      );

      expect(
        state().phase,
        const SyncRunFinished(
          applied: 4,
          skipped: 3,
          conflicts: 0,
          failed: 0,
          unreadable: 2,
        ),
      );
    });

    test('the review is the awaiting phase, its total on the bar\'s own '
        'cell, the choices on each row\'s', () async {
      await harness.show(
        runView(
          phase: reviewing(apply: 1, skipped: 1, keptBoth: 1),
          conflicts: [
            conflictRow(
              'both.txt',
              a: modifiedFile(),
              b: modifiedFile(),
              choice: wire.ConflictChoiceView.keepBoth,
            ),
          ],
          plan: [
            planRow(copyTo('new.txt')),
            planRow(
              deleteThere('gone.txt'),
              choice: wire.ActionChoiceView.skipped,
            ),
          ],
        ),
      );

      expect(state().phase, const SyncRunAwaitingDecisions());
      expect(
        state().decisionSummary.value,
        const SyncRunDecisionSummary(
          apply: 1,
          reversed: 0,
          skipped: 1,
          resolved: 0,
          keptBoth: 1,
          leftOpen: 0,
        ),
      );
      expect(
        state().actionDecisionCell(planRowAt('new.txt')).value,
        ActionChoice.proposed,
      );
      expect(
        state().actionDecisionCell(planRowAt('gone.txt')).value,
        ActionChoice.skipped,
      );
      expect(
        state().conflictDecisionCell(conflictAt('both.txt')).value,
        ConflictChoice.keepBoth,
      );

      // The review over: no total.
      await harness.show(runView(phase: applying));
      expect(state().decisionSummary.value, isNull);
    });

    test('the delete guard names each side, its folder and how many of how '
        'many files', () async {
      await harness.show(
        runView(
          phase: wire.RunPhaseViewConfirmingDeletes(
            sides: [
              wire.MassDeleteView(
                side: wire.SideView.a,
                deletes: n(12),
                archived: n(12),
              ),
              wire.MassDeleteView(
                side: wire.SideView.b,
                deletes: n(40),
                archived: n(50),
              ),
            ],
          ),
        ),
      );

      expect(
        state().phase,
        const SyncRunConfirmingDeletes([
          SyncRunDeletesOnSide(
            where: 'this device',
            root: '/data/notes',
            deletes: 12,
            archived: 12,
          ),
          SyncRunDeletesOnSide(
            where: 'the remote',
            root: '~/notes',
            deletes: 40,
            archived: 50,
          ),
        ]),
      );
    });
  });

  group('first sync', () {
    wire.RunView replicasOf({required bool aEmpty, required bool bEmpty}) =>
        runView(
          replicas: replicas(
            lastA: aEmpty ? null : now,
            lastB: bEmpty ? null : now,
          ),
        );

    test('both empty: the warning, worded as an expected first run', () async {
      await harness.show(replicasOf(aEmpty: true, bEmpty: true));

      final header = state().header!;
      expect(header.firstSyncWarning, firstSyncWarning);
      expect(header.firstSyncWarning, contains('never deleted'));
      expect(header.history, contains('First sync'));
      expect(header.history, isNot(contains('wiped')));
    });

    test('one side empty: the same warning, a history that names the side '
        'and the wiped-data possibility', () async {
      await harness.show(replicasOf(aEmpty: true, bEmpty: false));
      final thisEmpty = state().header!;

      await harness.show(replicasOf(aEmpty: false, bEmpty: true));
      final peerEmpty = state().header!;

      expect(thisEmpty.firstSyncWarning, firstSyncWarning);
      expect(peerEmpty.firstSyncWarning, firstSyncWarning);
      expect(thisEmpty.history, contains('This device has no archive'));
      expect(peerEmpty.history, contains('Remote has no archive'));
      expect(thisEmpty.history, contains('wiped'));
      expect(peerEmpty.history, contains('wiped'));
    });

    test('the asymmetric wording differs from both-empty', () async {
      await harness.show(replicasOf(aEmpty: true, bEmpty: true));
      final both = state().header!.history;
      await harness.show(replicasOf(aEmpty: true, bEmpty: false));
      final one = state().header!.history;

      expect(both, isNot(one));
      // Positive controls: each contains its own distinguishing text.
      expect(both, contains('First sync of this pair.'));
      expect(one, contains('has no archive'));
      expect(both, isNot(contains('has no archive')));
    });

    test('neither empty: no warning', () async {
      await harness.show(replicasOf(aEmpty: false, bEmpty: false));

      expect(state().header!.firstSyncWarning, isNull);
      expect(state().header!.history, isNot(contains('First sync')));
    });
  });

  group('how a run ends, worded', () {
    test('a failure in the core\'s own words, and nothing else', () async {
      // The core words SPEC §4.4's root refusal; the head adds nothing that
      // could claim the path does or does not exist.
      const refusal =
          'replica b: desktop has not granted this path to this device';
      await harness.show(runView(phase: failedWith(refusal)));

      expect(state().phase, const SyncRunFailed(refusal));
      expect(state().header, isNull);
      expect(state().plan, isEmpty);
    });

    test(
      'a held replica lock is its own phase, in the core\'s words',
      () async {
        await harness.show(runView(phase: replicaBusy('in use (lock file x)')));

        expect(state().phase, const SyncRunReplicaBusy('in use (lock file x)'));
      },
    );

    test('declined deletions read as the user\'s choice', () async {
      await harness.show(
        runView(phase: const wire.RunPhaseViewDeletesDeclined()),
      );

      expect(state().phase, const SyncRunFailed(deletesDeclinedMessage));
    });

    test('a run that ended without a summary says so', () async {
      await harness.show(runView(phase: const wire.RunPhaseViewNoSummary()));

      expect(
        (state().phase as SyncRunFailed).message,
        contains('without reporting a summary'),
      );
    });

    test(
      'stopped: the number of actions completed, never "cancelled"',
      () async {
        await harness.show(runView(phase: stopped(2)));

        final phase = state().phase as SyncRunStopped;
        expect(phase.completedActions, 2);
        final message = stoppedMessage(phase.completedActions);
        expect(message, contains('after 2 action'));
        expect(message.toLowerCase(), isNot(contains('cancel')));
        expect(message, contains('nothing further'));
      },
    );

    test('paused: the same count, under its own phase', () async {
      await harness.show(runView(phase: paused(1)));

      final phase = state().phase as SyncRunPaused;
      expect(phase.completedActions, 1);
      final message = pausedMessage(phase.completedActions);
      expect(message, contains('after 1 action'));
      expect(message, contains('continues when you come back'));
    });

    test('the next attempt\'s view shows nothing of the last, cells '
        'included', () async {
      await harness.show(happy);
      final cell = state().resultCell('new.txt');
      expect(state().plan, isNotEmpty);
      expect(cell.value, isNotNull);

      await harness.show(runView(phase: connecting));

      expect(state().phase, isA<SyncRunConnecting>());
      expect(state().header, isNull);
      expect(state().scanTally, isNull);
      expect(state().conflicts, isEmpty);
      expect(state().skippedSymlinks, isEmpty);
      expect(state().unreadablePaths, isEmpty);
      expect(state().plan, isEmpty);
      expect(state().planSections[SyncRunPlanGroup.toDevice]!.indexes, isEmpty);
      expect(state().bytesToTransfer, 0);
      expect(state().appliedCount, 0);
      expect(state().failedCount, 0);
      expect(state().progress, isNull);
      expect(state().startedAt, isNull);
      // The same cell a built row is already watching, emptied rather than
      // dropped.
      expect(cell.value, isNull);
      expect(state().resultCell('new.txt'), same(cell));
    });
  });

  group('what a view wakes', () {
    test('the same plan with one more result: that row\'s cell, never the '
        'plan or the phase', () async {
      final rows = [planRow(copyTo('a.txt')), planRow(copyTo('b.txt'))];
      await harness.show(runView(phase: applying, plan: rows));
      final a = state().resultCell('a.txt');
      final b = state().resultCell('b.txt');
      var plan = 0, phase = 0, aFired = 0, bFired = 0, notified = 0;
      state()
        ..addListener(() => notified++)
        ..planChanged.addListener(() => plan++)
        ..phaseChanged.addListener(() => phase++);
      a.addListener(() => aFired++);
      b.addListener(() => bFired++);

      await harness.show(
        runView(
          phase: applying,
          plan: [
            planRow(copyTo('a.txt'), outcome: outcome(copyTo('a.txt'))),
            planRow(copyTo('b.txt')),
          ],
          progress: (completed: 1, total: 2),
          applied: 1,
        ),
      );

      // Positive control: the result's own cell, and the page's values.
      expect(aFired, 1);
      expect(notified, 1);
      expect(state().appliedCount, 1);
      expect((plan, phase, bFired), (0, 0, 0));

      // A new phase wakes the phase.
      await harness.show(runView(phase: finished(applied: 1), plan: rows));
      expect(phase, 1);
      expect(plan, 0);
    });

    test('a choice moves its row\'s cell and the total, and nothing '
        'else', () async {
      final conflicts = [
        conflictRow('c.txt', a: modifiedFile(), b: modifiedFile()),
      ];
      await harness.show(
        runView(
          phase: reviewing(apply: 2, leftOpen: 1),
          conflicts: conflicts,
          plan: [
            planRow(copyTo('a.txt'), reverseBytes: 4),
            planRow(copyTo('b.txt')),
          ],
        ),
      );
      final tapped = state().actionDecisionCell(planRowAt('a.txt'));
      final other = state().actionDecisionCell(planRowAt('b.txt'));
      final conflict = state().conflictDecisionCell(conflictAt('c.txt'));
      var tappedFired = 0, otherFired = 0, conflictFired = 0;
      var summaryFired = 0, plan = 0, phase = 0;
      tapped.addListener(() => tappedFired++);
      other.addListener(() => otherFired++);
      conflict.addListener(() => conflictFired++);
      state().decisionSummary.addListener(() => summaryFired++);
      state().planChanged.addListener(() => plan++);
      state().phaseChanged.addListener(() => phase++);

      await harness.show(
        runView(
          phase: reviewing(apply: 2, reversed: 1, leftOpen: 1),
          conflicts: conflicts,
          plan: [
            planRow(
              copyTo('a.txt'),
              reverseBytes: 4,
              choice: wire.ActionChoiceView.reversed,
            ),
            planRow(copyTo('b.txt')),
          ],
        ),
      );

      expect(tapped.value, ActionChoice.reversed);
      expect((tappedFired, summaryFired), (1, 1));
      expect((otherFired, conflictFired, plan, phase), (0, 0, 0, 0));
      // A cell first read after the choice starts at it.
      expect(state().actionDecisionCell(planRowAt('a.txt')), same(tapped));
    });
  });
}
