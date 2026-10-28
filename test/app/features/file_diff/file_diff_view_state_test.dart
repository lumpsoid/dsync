import 'package:dsync/app/core_link/models/compared_side.dart';
import 'package:dsync/app/core_link/models/diff_hunk.dart';
import 'package:dsync/app/core_link/models/file_comparison.dart';
import 'package:dsync/app/core_link/models/replica_side.dart';
import 'package:dsync/app/core_link/models/row_ref.dart';
import 'package:dsync/app/features/file_diff/file_diff_layout.dart';
import 'package:dsync/app/features/file_diff/file_diff_view_state.dart';
import 'package:flutter_test/flutter_test.dart';

/// Covers the diff's flattening ([FileDiffText.of]) over plain hunks, the
/// sentence each non-text verdict reads as, the reading line, and the
/// layout's breakpoint.
void main() {
  DiffLine plain(String text) => DiffLine([DiffSpan(text, emphasized: false)]);

  /// Old lines 3..8 then 20; new lines 3..6 then 18:
  ///
  /// ```
  /// (2 unchanged)  a b  -x1 -x2 -x3 +y1  c  (11 unchanged)  +z
  /// ```
  const hunks = [
    DiffHunk(
      oldStart: 3,
      newStart: 3,
      blocks: [
        SameBlock(['a', 'b']),
        ChangedBlock(
          oldLines: [
            DiffLine([DiffSpan('x1', emphasized: false)]),
            DiffLine([DiffSpan('x2', emphasized: false)]),
            DiffLine([DiffSpan('x3', emphasized: false)]),
          ],
          newLines: [
            DiffLine([
              DiffSpan('y', emphasized: false),
              DiffSpan('1', emphasized: true),
            ]),
          ],
        ),
        SameBlock(['c']),
      ],
    ),
    DiffHunk(
      oldStart: 20,
      newStart: 18,
      blocks: [
        ChangedBlock(
          oldLines: [],
          newLines: [
            DiffLine([DiffSpan('z', emphasized: false)]),
          ],
        ),
      ],
    ),
  ];

  String text(List<DiffSpan> spans) => spans.map((s) => s.text).join();

  Object? unified(FileDiffRow row) => switch (row) {
    DiffGapRow(:final count) => count,
    UnifiedLineRow(:final mark, :final oldNumber, :final newNumber) => (
      mark.sign,
      oldNumber,
      newNumber,
      text(row.spans),
    ),
    SplitLineRow() => fail('a split row in the unified list'),
  };

  Object? cell(DiffCell? cell) =>
      cell == null ? null : (cell.mark.sign, cell.number, text(cell.spans));

  Object? split(FileDiffRow row) => switch (row) {
    DiffGapRow(:final count) => count,
    SplitLineRow(:final oldCell, :final newCell) => (
      cell(oldCell),
      cell(newCell),
    ),
    UnifiedLineRow() => fail('a unified row in the split list'),
  };

  group('flattening a text diff', () {
    test('unified: numbers count from each hunk start, old lines then new, '
        'gaps before the first hunk and between hunks', () {
      final diff = FileDiffText.of(hunks);
      expect(diff.unified.map(unified).toList(), [
        2,
        (' ', 3, 3, 'a'),
        (' ', 4, 4, 'b'),
        ('−', 5, null, 'x1'),
        ('−', 6, null, 'x2'),
        ('−', 7, null, 'x3'),
        ('+', null, 5, 'y1'),
        (' ', 8, 6, 'c'),
        11,
        ('+', null, 18, 'z'),
      ]);
      expect(diff.numberWidth, 2);
    });

    test('split: a 3-old/1-new block is 3 paired rows, the new side '
        'padded twice', () {
      final diff = FileDiffText.of(hunks);
      expect(diff.split.map(split).toList(), [
        2,
        ((' ', 3, 'a'), (' ', 3, 'a')),
        ((' ', 4, 'b'), (' ', 4, 'b')),
        (('−', 5, 'x1'), ('+', 5, 'y1')),
        (('−', 6, 'x2'), null),
        (('−', 7, 'x3'), null),
        ((' ', 8, 'c'), (' ', 6, 'c')),
        11,
        (null, ('+', 18, 'z')),
      ]);
    });

    test('a hunk at line 1 has no gap before it, and nothing is claimed '
        'after the last hunk', () {
      final diff = FileDiffText.of([
        DiffHunk(
          oldStart: 1,
          newStart: 1,
          blocks: [
            ChangedBlock(oldLines: [plain('o')], newLines: [plain('n')]),
          ],
        ),
      ]);
      expect(diff.unified.map(unified).toList(), [
        ('−', 1, null, 'o'),
        ('+', null, 1, 'n'),
      ]);
    });

    test('the gap label counts lines', () {
      expect(const DiffGapRow(1).label, '⋯ 1 unchanged line');
      expect(const DiffGapRow(11).label, '⋯ 11 unchanged lines');
    });
  });

  group('one sentence per verdict without a text diff', () {
    const a = ComparedSide(ReplicaSide.a, 10);
    const b = ComparedSide(ReplicaSide.b, 12);
    String sentence(FileComparison comparison) =>
        (FileDiffShown.of(comparison) as FileDiffSentence).sentence;

    test('each reads as its sentence', () {
      expect(
        sentence(const NotComparable()),
        'Nothing to compare for this row',
      );
      expect(
        sentence(const MediaFile(path: 'p', oldSide: a, newSide: b)),
        'Media file — not compared',
      );
      expect(
        sentence(
          const TooLargeFile(
            path: 'p',
            oldSide: a,
            newSide: b,
            side: ReplicaSide.a,
            size: 5 << 20,
          ),
        ),
        'Larger than 4 MB on This device',
      );
      expect(
        sentence(
          const BinaryFile(
            path: 'p',
            oldSide: a,
            newSide: b,
            side: ReplicaSide.b,
          ),
        ),
        'Binary file on Remote — no text diff',
      );
      expect(
        sentence(
          const UnreadableFile(
            path: 'p',
            oldSide: a,
            newSide: b,
            side: ReplicaSide.b,
            message: 'denied',
          ),
        ),
        "Couldn't read on Remote: denied",
      );
      expect(
        sentence(
          const SameText(path: 'p', oldSide: a, newSide: b, bytesDiffer: true),
        ),
        'Same text; line endings or a byte-order mark differ',
      );
      expect(
        sentence(
          const SameText(path: 'p', oldSide: a, newSide: b, bytesDiffer: false),
        ),
        'Same text',
      );
    });

    test('a text diff is rows, not a sentence', () {
      expect(
        FileDiffShown.of(
          const TextChanges(path: 'p', oldSide: a, newSide: b, hunks: hunks),
        ),
        isA<FileDiffText>(),
      );
    });
  });

  group('the reading line', () {
    String reading(ComparedSide oldSide, ComparedSide newSide) {
      final state = FileDiffViewState()
        ..recordReading(
          FileDiffArgs(
            session: 1,
            row: const ActionRowRef(0),
            path: 'p',
            oldSide: oldSide,
            newSide: newSide,
          ),
        );
      return (state.view as FileDiffReading).line;
    }

    test('names the remote side and its size when it has a file', () {
      expect(
        reading(
          const ComparedSide(ReplicaSide.a, 100),
          const ComparedSide(ReplicaSide.b, 13 * 1024),
        ),
        'Reading Remote · 13 KiB…',
      );
    });

    test('reads both files when no side is a remote one with a file', () {
      expect(
        reading(
          const ComparedSide(ReplicaSide.a, 100),
          const ComparedSide(ReplicaSide.b, null),
        ),
        'Reading both files…',
      );
      expect(
        reading(
          const ComparedSide(ReplicaSide.a, 100),
          const ComparedSide(ReplicaSide.a, 200),
        ),
        'Reading both files…',
      );
    });
  });

  test('the layout splits at the extended rail breakpoint', () {
    expect(FileDiffLayout.forWidth(1199), FileDiffLayout.unified);
    expect(FileDiffLayout.forWidth(1200), FileDiffLayout.split);
  });
}
