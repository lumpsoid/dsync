import 'package:dsync/app/core_link/core_link.dart';
import 'package:dsync/app/core_link/models/action_choice.dart';
import 'package:dsync/app/core_link/models/core_failure.dart';
import 'package:dsync/app/core_link/models/diff_hunk.dart';
import 'package:dsync/app/core_link/models/entry_draft.dart';
import 'package:dsync/app/core_link/models/file_comparison.dart';
import 'package:dsync/app/core_link/models/profile_draft.dart';
import 'package:dsync/app/core_link/models/profile_entry.dart';
import 'package:dsync/app/core_link/models/replica_side.dart';
import 'package:dsync/app/core_link/models/root_kind.dart';
import 'package:dsync/app/core_link/models/row_ref.dart';
import 'package:dsync/app/core_link/models/run_intent.dart';
import 'package:dsync/app/core_link/models/run_phase.dart';
import 'package:dsync/app/core_link/models/run_target.dart';
import 'package:dsync/app/core_link/models/run_view.dart';
import 'package:dsync/app/rust/bindings/bindings.dart' as wire;
import 'package:flutter_test/flutter_test.dart';

import '../features/run/run_fixtures.dart';
import '../support/fake_hub.dart';

/// The [CoreLink] the head's controller tests run on, over the fake hub:
/// a session's snapshots reach its own stream, decoded by the link the app
/// runs, and end with the one the hub marks its last.
void main() {
  test('a run session\'s views are the hub\'s snapshots, decoded, and '
      'its intents are sent as they are', () async {
    final hub = FakeHub();
    final link = CoreLink(hub);
    final run = await link.startRun(
      const DraftTarget(
        ProfileDraft(
          peerDeviceId: 'x',
          entries: [EntryDraft(localRoot: '/a', remoteRoot: '/b')],
        ),
      ),
      dryRun: false,
      defaultWarnSizeBytes: null,
      massDeleteMinFiles: 10,
      massDeletePercent: 50,
    );
    final views = <RunView>[];
    final listening = run.views.listen(views.add);
    hub.emitRun(run.session, runView(phase: reviewing(apply: 2)), last: false);
    await link.steerRun(
      run.session,
      const ChooseAction(1, ActionChoice.skipped),
    );
    await link.steerRun(run.session, const ConfirmReview());
    await Future<void>.delayed(Duration.zero);

    expect(views.single.phase, isA<RunReviewing>());
    expect((views.single.phase as RunReviewing).summary.apply, 2);
    expect(
      [for (final steer in hub.sent<wire.CoreCommandSteerRun>()) steer.intent],
      const [
        wire.RunIntentChooseAction(
          index: 1,
          choice: wire.ActionChoiceView.skipped,
        ),
        wire.RunIntentConfirm(),
      ],
    );

    // Once nobody listens, the session is forgotten: what arrives for it
    // is dropped.
    await listening.cancel();
    hub.emitRun(run.session, runView(phase: applying), last: false);
    await Future<void>.delayed(Duration.zero);
    expect(views, hasLength(1));
  });

  test('a session\'s stream ends with the snapshot the hub marks its '
      'last, and nothing after it is seen', () async {
    final hub = FakeHub();
    final link = CoreLink(hub);
    final run = await link.startRun(
      const DraftTarget(
        ProfileDraft(
          peerDeviceId: 'x',
          entries: [EntryDraft(localRoot: '/a', remoteRoot: '/b')],
        ),
      ),
      dryRun: false,
      defaultWarnSizeBytes: null,
      massDeleteMinFiles: 10,
      massDeletePercent: 50,
    );
    final views = run.views.toList();
    hub
      ..emitRun(run.session, runView(phase: applying), last: false)
      ..emitRun(
        run.session,
        runView(standing: over, phase: finished()),
        last: true,
      )
      ..emitRun(run.session, runView(phase: connecting), last: false);

    final seen = await views;
    expect(
      [for (final view in seen) view.phase.runtimeType],
      [RunApplying, RunFinished],
    );
  });

  test('a two-entry profile crosses the wire whole, both ways', () async {
    final hub = FakeHub();
    final link = CoreLink(hub);
    // The hub's bytes, decoded as the app's channel decodes them.
    final listed = wire.ReplyResult.bincodeDeserialize(
      const wire.ReplyResultProfiles(
        value: [
          wire.ProfileEntryHead(
            value: wire.ProfileView(
              name: 'weekly',
              peerDeviceId: 'aaaa',
              peerName: 'desktop',
              jobs: 3,
              ignore: ['**/.git'],
              lastRunUnfinished: true,
              entries: [
                wire.EntryView(
                  entryId: 'e1',
                  kind: wire.RootKindView.folder,
                  localRoot: '~/Notes',
                  localRootExpanded: '/home/u/Notes',
                  localRootRefusal: null,
                  remoteRoot: '/srv/notes',
                ),
                wire.EntryView(
                  entryId: 'e2',
                  kind: wire.RootKindView.file,
                  localRoot: '/sdcard/todo.md',
                  localRootExpanded: '/sdcard/todo.md',
                  localRootRefusal: 'dsync cannot use /sdcard',
                  remoteRoot: '/srv/todo.md',
                ),
              ],
            ),
          ),
        ],
      ).bincodeSerialize(),
    );
    hub.reply<wire.CoreCommandListProfiles>(listed);

    final profile = (await link.listProfiles()).single as HeadProfile;

    expect(profile.name, 'weekly');
    expect(profile.lastRunUnfinished, isTrue);
    expect(
      [
        for (final entry in profile.entries)
          (
            entry.entryId,
            entry.kind,
            entry.localRoot,
            entry.localRootExpanded,
            entry.localRootRefusal,
            entry.remoteRoot,
          ),
      ],
      [
        ('e1', RootKind.folder, '~/Notes', '/home/u/Notes', null, '/srv/notes'),
        (
          'e2',
          RootKind.file,
          '/sdcard/todo.md',
          '/sdcard/todo.md',
          'dsync cannot use /sdcard',
          '/srv/todo.md',
        ),
      ],
    );

    hub.reply<wire.CoreCommandSaveProfile>(listed);
    await link.saveProfile(
      'weekly',
      const ProfileDraft(
        peerDeviceId: 'aaaa',
        entries: [
          EntryDraft(localRoot: '~/Notes', remoteRoot: '/srv/notes'),
          EntryDraft(
            kind: RootKind.file,
            localRoot: '/sdcard/todo.md',
            remoteRoot: '/srv/todo.md',
          ),
        ],
      ),
    );
    final sent = hub.sent<wire.CoreCommandSaveProfile>().single.draft;
    expect(
      wire.ProfileDraft.bincodeDeserialize(sent.bincodeSerialize()),
      const wire.ProfileDraft(
        peerDeviceId: 'aaaa',
        entries: [
          wire.EntryDraft(
            kind: wire.RootKindView.folder,
            localRoot: '~/Notes',
            remoteRoot: '/srv/notes',
          ),
          wire.EntryDraft(
            kind: wire.RootKindView.file,
            localRoot: '/sdcard/todo.md',
            remoteRoot: '/srv/todo.md',
          ),
        ],
        jobs: null,
        ignore: [],
      ),
    );
  });

  group('comparing a row', () {
    wire.SidedView sided(wire.SideView side, int? size) =>
        wire.SidedView(side: side, size: size == null ? null : n(size));

    Future<FileComparison> compare(wire.ComparisonView view) {
      final hub = FakeHub()
        ..reply<wire.CoreCommandCompareRow>(
          wire.ReplyResultComparison(value: view),
        );
      return CoreLink(hub).compareRow(1, const ActionRowRef(0)).reply;
    }

    wire.ComparisonView compared(wire.ComparedView verdict) =>
        wire.ComparisonViewCompared(
          path: 'd/x.txt',
          oldSide: sided(wire.SideView.b, null),
          newSide: sided(wire.SideView.a, 0),
          verdict: verdict,
        );

    test('every verdict reads as its comparison, with path, sides and '
        'sizes (no file is null, an empty file is 0)', () async {
      expect(
        await compare(const wire.ComparisonViewNotComparable()),
        isA<NotComparable>(),
      );
      final verdicts = <wire.ComparedView, Matcher>{
        const wire.ComparedViewMedia(): isA<MediaFile>(),
        wire.ComparedViewTooLarge(
          side: wire.SideView.a,
          size: n(7),
        ): isA<TooLargeFile>()
            .having((f) => f.side, 'side', ReplicaSide.a)
            .having((f) => f.size, 'size', 7),
        const wire.ComparedViewBinary(side: wire.SideView.b): isA<BinaryFile>()
            .having((f) => f.side, 'side', ReplicaSide.b),
        const wire.ComparedViewUnreadable(
          side: wire.SideView.b,
          message: 'denied',
        ): isA<UnreadableFile>()
            .having((f) => f.side, 'side', ReplicaSide.b)
            .having((f) => f.message, 'message', 'denied'),
        const wire.ComparedViewIdentical(bytesDiffer: true): isA<SameText>()
            .having((f) => f.bytesDiffer, 'bytesDiffer', true),
      };
      for (final MapEntry(key: verdict, value: matcher) in verdicts.entries) {
        final read = await compare(compared(verdict));
        expect(read, matcher, reason: '$verdict');
        read as ComparedFile;
        expect(read.path, 'd/x.txt');
        expect(read.oldSide.side, ReplicaSide.b);
        expect(read.oldSide.size, isNull);
        expect(read.newSide.side, ReplicaSide.a);
        expect(read.newSide.size, 0);
      }
    });

    test('hunks keep their blocks, lines and emphasized spans', () async {
      final read = await compare(
        compared(
          const wire.ComparedViewHunks(
            value: [
              wire.HunkView(
                oldStart: 3,
                newStart: 4,
                blocks: [
                  wire.BlockViewSame(value: ['keep']),
                  wire.BlockViewChanged(
                    oldLines: [
                      wire.LineView(
                        spans: [
                          wire.SpanView(text: 'a ', emphasized: false),
                          wire.SpanView(text: 'old', emphasized: true),
                        ],
                      ),
                    ],
                    newLines: [
                      wire.LineView(
                        spans: [wire.SpanView(text: 'new', emphasized: true)],
                      ),
                    ],
                  ),
                ],
              ),
            ],
          ),
        ),
      );
      final hunk = (read as TextChanges).hunks.single;
      expect(hunk.oldStart, 3);
      expect(hunk.newStart, 4);
      final [same, changed] = hunk.blocks;
      expect((same as SameBlock).lines, ['keep']);
      final block = changed as ChangedBlock;
      expect(
        [
          for (final span in block.oldLines.single.spans)
            (span.text, span.emphasized),
        ],
        [('a ', false), ('old', true)],
      );
      expect(
        [
          for (final span in block.newLines.single.spans)
            (span.text, span.emphasized),
        ],
        [('new', true)],
      );
    });

    test('an action and a conflict are asked for by their index; cancel '
        'names the compare\'s own request', () async {
      final hub = FakeHub()
        ..reply<wire.CoreCommandCompareRow>(
          const wire.ReplyResultComparison(
            value: wire.ComparisonViewNotComparable(),
          ),
        );
      final link = CoreLink(hub);
      final first = link.compareRow(5, const ActionRowRef(2));
      final second = link.compareRow(5, const ConflictRowRef(1));
      await first.reply;
      await second.reply;
      await link.cancelCompare(5, second.id);

      final [a, c] = hub.sent<wire.CoreCommandCompareRow>();
      expect(a.session.toInt(), 5);
      expect(a.row, const wire.RowRefAction(index: 2));
      expect(c.row, const wire.RowRefConflict(index: 1));
      final ids = [
        for (final r in hub.requests)
          if (r.command is wire.CoreCommandCompareRow) r.id.toInt(),
      ];
      expect(ids, [first.id, second.id]);
      expect(first.id, isNot(second.id));
      final cancel = hub.sent<wire.CoreCommandCancelCompare>().single;
      expect(cancel.session.toInt(), 5);
      expect(cancel.request.toInt(), second.id);
      expect(hub.cancelledCompares, [second.id]);
    });

    test('a held compare, cancelled, fails with cancelled', () async {
      final hub = FakeHub()..holdCompareUntilCancelled();
      final link = CoreLink(hub);
      final compare = link.compareRow(1, const ActionRowRef(0));
      var settled = false;
      final failure = compare.reply.then<Object?>(
        (_) => null,
        onError: (Object e) => e,
      )..whenComplete(() => settled = true);
      await Future<void>.delayed(Duration.zero);
      expect(settled, isFalse);

      await link.cancelCompare(1, compare.id);

      expect(
        await failure,
        isA<CoreFailure>().having((f) => f.message, 'message', 'cancelled'),
      );
    });
  });
}
