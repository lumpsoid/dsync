import 'package:flutter/foundation.dart';

import '../../core_link/models/compared_side.dart';
import '../../core_link/models/diff_hunk.dart';
import '../../core_link/models/file_comparison.dart';
import '../../core_link/models/replica_side.dart';
import '../../core_link/models/row_ref.dart';
import '../../format_bytes.dart';

/// What the diff page was opened over: a review row, by its run [session]
/// and its place in the plan ([row]), and what that row already shows —
/// its [path] and its two sides — so the page has a header before the
/// core has read a byte.
///
/// An id plus the facts the review row has on screen, not loaded data: the
/// comparison itself is the page's to read, and once it is read its own
/// sides replace [oldSide] and [newSide] in the header.
class FileDiffArgs {
  const FileDiffArgs({
    required this.session,
    required this.row,
    required this.path,
    required this.oldSide,
    required this.newSide,
  });

  final int session;
  final RowRef row;
  final String path;

  /// The side the row would replace, as the review row knows it.
  final ComparedSide oldSide;

  /// The side the row would put in its place.
  final ComparedSide newSide;
}

/// What the page shows under its header.
sealed class FileDiffView {
  const FileDiffView();
}

/// The core is reading the files; [line] says which, and how much.
final class FileDiffReading extends FileDiffView {
  const FileDiffReading(this.line);

  final String line;
}

/// The comparison could not be made, for [message].
final class FileDiffFailed extends FileDiffView {
  const FileDiffFailed(this.message);

  final String message;
}

/// The comparison, read: a sentence when there is no text diff to draw,
/// or the diff's rows.
sealed class FileDiffShown extends FileDiffView {
  const FileDiffShown();

  /// The view of [comparison]: its rows are built here, once, rather than
  /// in every `build`.
  factory FileDiffShown.of(FileComparison comparison) => switch (comparison) {
    NotComparable() => const FileDiffSentence(
      'Nothing to compare for this row',
    ),
    MediaFile() => const FileDiffSentence('Media file — not compared'),
    TooLargeFile(:final side, :final maxBytes) => FileDiffSentence(
      'Larger than ${maxBytes ~/ (1024 * 1024)} MB on '
      '${replicaName(side)}',
    ),
    BinaryFile(:final side) => FileDiffSentence(
      'Binary file on ${replicaName(side)} — no text diff',
    ),
    UnreadableFile(:final side, :final message) => FileDiffSentence(
      "Couldn't read on ${replicaName(side)}: $message",
    ),
    SameText(bytesDiffer: true) => const FileDiffSentence(
      'Same text; line endings or a byte-order mark differ',
    ),
    SameText(bytesDiffer: false) => const FileDiffSentence('Same text'),
    TextChanges(:final hunks) => FileDiffText.of(hunks),
  };
}

/// A verdict with no text diff, said in one sentence.
final class FileDiffSentence extends FileDiffShown {
  const FileDiffSentence(this.sentence);

  final String sentence;
}

/// A text diff, flattened into the rows each layout draws: [unified] for
/// one column, [split] for two side by side.
final class FileDiffText extends FileDiffShown {
  const FileDiffText({
    required this.unified,
    required this.split,
    required this.numberWidth,
  });

  /// Flattens [hunks]. A line's number is its hunk's start plus the lines
  /// of that side before it in the hunk; a run of lines between hunks, or
  /// before the first, becomes one [DiffGapRow]. What follows the last
  /// hunk is not known — the wire carries no line count — so no row
  /// claims it.
  factory FileDiffText.of(List<DiffHunk> hunks) {
    final unified = <FileDiffRow>[];
    final split = <FileDiffRow>[];
    var widest = 1;
    int? nextOld;
    for (final hunk in hunks) {
      final gap = hunk.oldStart - (nextOld ?? 1);
      if (gap > 0) {
        unified.add(DiffGapRow(gap));
        split.add(DiffGapRow(gap));
      }
      var oldNumber = hunk.oldStart;
      var newNumber = hunk.newStart;
      for (final block in hunk.blocks) {
        switch (block) {
          case SameBlock(:final lines):
            for (final line in lines) {
              final spans = [DiffSpan(line, emphasized: false)];
              unified.add(
                UnifiedLineRow(
                  mark: DiffMark.same,
                  oldNumber: oldNumber,
                  newNumber: newNumber,
                  spans: spans,
                ),
              );
              split.add(
                SplitLineRow(
                  oldCell: DiffCell(DiffMark.same, oldNumber, spans),
                  newCell: DiffCell(DiffMark.same, newNumber, spans),
                ),
              );
              oldNumber++;
              newNumber++;
            }
          case ChangedBlock(:final oldLines, :final newLines):
            for (final (i, line) in oldLines.indexed) {
              unified.add(
                UnifiedLineRow(
                  mark: DiffMark.removed,
                  oldNumber: oldNumber + i,
                  newNumber: null,
                  spans: line.spans,
                ),
              );
            }
            for (final (i, line) in newLines.indexed) {
              unified.add(
                UnifiedLineRow(
                  mark: DiffMark.added,
                  oldNumber: null,
                  newNumber: newNumber + i,
                  spans: line.spans,
                ),
              );
            }
            final pairs = oldLines.length > newLines.length
                ? oldLines.length
                : newLines.length;
            for (var i = 0; i < pairs; i++) {
              split.add(
                SplitLineRow(
                  oldCell: i < oldLines.length
                      ? DiffCell(
                          DiffMark.removed,
                          oldNumber + i,
                          oldLines[i].spans,
                        )
                      : null,
                  newCell: i < newLines.length
                      ? DiffCell(
                          DiffMark.added,
                          newNumber + i,
                          newLines[i].spans,
                        )
                      : null,
                ),
              );
            }
            oldNumber += oldLines.length;
            newNumber += newLines.length;
        }
      }
      nextOld = oldNumber;
      final last = oldNumber > newNumber ? oldNumber : newNumber;
      final digits = '${last - 1}'.length;
      if (digits > widest) widest = digits;
    }
    return FileDiffText(unified: unified, split: split, numberWidth: widest);
  }

  final List<FileDiffRow> unified;
  final List<FileDiffRow> split;

  /// The digits of the largest line number shown, so a gutter is one
  /// width all the way down.
  final int numberWidth;
}

/// Whether a line is on both sides, only the old, or only the new — with
/// the mark that says so, so colour is never the only cue.
enum DiffMark {
  same(' '),
  removed('−'),
  added('+');

  const DiffMark(this.sign);

  final String sign;
}

/// One row of a flattened diff.
sealed class FileDiffRow {
  const FileDiffRow();
}

/// [count] lines both sides share, not shown.
final class DiffGapRow extends FileDiffRow {
  const DiffGapRow(this.count);

  final int count;

  String get label => '⋯ $count unchanged ${count == 1 ? 'line' : 'lines'}';
}

/// One line of the single-column diff: a same line has both numbers, a
/// removed line only [oldNumber], an added line only [newNumber].
final class UnifiedLineRow extends FileDiffRow {
  const UnifiedLineRow({
    required this.mark,
    required this.oldNumber,
    required this.newNumber,
    required this.spans,
  });

  final DiffMark mark;
  final int? oldNumber;
  final int? newNumber;
  final List<DiffSpan> spans;
}

/// One row of the two-column diff. A null side is padding: the other side
/// has more changed lines in this block, and the blank keeps the columns
/// aligned.
final class SplitLineRow extends FileDiffRow {
  const SplitLineRow({required this.oldCell, required this.newCell});

  final DiffCell? oldCell;
  final DiffCell? newCell;
}

/// One side's line in a [SplitLineRow].
final class DiffCell {
  const DiffCell(this.mark, this.number, this.spans);

  final DiffMark mark;
  final int number;
  final List<DiffSpan> spans;
}

/// A replica side by the name the run review gives it.
String replicaName(ReplicaSide side) => switch (side) {
  ReplicaSide.a => 'This device',
  ReplicaSide.b => 'Remote',
};

/// A side as the header shows it: its name, and its size or that it has
/// no file.
String sideLabel(ComparedSide side) => switch (side.size) {
  null => '${replicaName(side.side)} · no file',
  final size => '${replicaName(side.side)} · ${formatBytes(size)}',
};

/// The diff page's view: the header — [path] and the two sides — and what
/// is under it.
class FileDiffViewState extends ChangeNotifier {
  String _path = '';
  String _oldSide = '';
  String _newSide = '';
  FileDiffView _view = const FileDiffReading('');

  String get path => _path;

  /// The old side's header label, "Remote · 13 KiB".
  String get oldSide => _oldSide;

  /// The new side's header label.
  String get newSide => _newSide;

  FileDiffView get view => _view;

  /// A read starting over [args]: the header is what the row knows, and
  /// the body says what is being read.
  void recordReading(FileDiffArgs args) {
    _path = args.path;
    _oldSide = sideLabel(args.oldSide);
    _newSide = sideLabel(args.newSide);
    final remote = [
      args.oldSide,
      args.newSide,
    ].where((s) => s.side == ReplicaSide.b && s.size != null).firstOrNull;
    _view = FileDiffReading(
      remote == null ? 'Reading both files…' : 'Reading ${sideLabel(remote)}…',
    );
    notifyListeners();
  }

  /// The comparison, read; a compared file's own path and sides replace
  /// what the row said.
  void recordComparison(FileComparison comparison) {
    if (comparison case ComparedFile(
      :final path,
      :final oldSide,
      :final newSide,
    )) {
      _path = path;
      _oldSide = sideLabel(oldSide);
      _newSide = sideLabel(newSide);
    }
    _view = FileDiffShown.of(comparison);
    notifyListeners();
  }

  void recordFailure(String message) {
    _view = FileDiffFailed(message);
    notifyListeners();
  }
}
