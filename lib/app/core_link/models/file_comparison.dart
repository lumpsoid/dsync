import 'compared_side.dart';
import 'diff_hunk.dart';
import 'replica_side.dart';

/// What comparing a review row's two files came to.
sealed class FileComparison {
  const FileComparison();
}

/// The row has nothing to compare, or no such row.
final class NotComparable extends FileComparison {
  const NotComparable();
}

/// A comparison of the file at [path]: [oldSide] is what the row would
/// replace, [newSide] what it would put there.
sealed class ComparedFile extends FileComparison {
  const ComparedFile({
    required this.path,
    required this.oldSide,
    required this.newSide,
  });

  final String path;
  final ComparedSide oldSide;
  final ComparedSide newSide;
}

final class MediaFile extends ComparedFile {
  const MediaFile({
    required super.path,
    required super.oldSide,
    required super.newSide,
  });
}

/// The file on [side] is [size] bytes, too large to read.
final class TooLargeFile extends ComparedFile {
  const TooLargeFile({
    required super.path,
    required super.oldSide,
    required super.newSide,
    required this.side,
    required this.size,
  });

  final ReplicaSide side;
  final int size;
}

/// The file on [side] is not text.
final class BinaryFile extends ComparedFile {
  const BinaryFile({
    required super.path,
    required super.oldSide,
    required super.newSide,
    required this.side,
  });

  final ReplicaSide side;
}

/// The file on [side] could not be read, for [message].
final class UnreadableFile extends ComparedFile {
  const UnreadableFile({
    required super.path,
    required super.oldSide,
    required super.newSide,
    required this.side,
    required this.message,
  });

  final ReplicaSide side;
  final String message;
}

/// The two read as the same text; [bytesDiffer] when their bytes still
/// differ (line endings, say).
final class SameText extends ComparedFile {
  const SameText({
    required super.path,
    required super.oldSide,
    required super.newSide,
    required this.bytesDiffer,
  });

  final bool bytesDiffer;
}

/// The two differ as text, in [hunks].
final class TextChanges extends ComparedFile {
  const TextChanges({
    required super.path,
    required super.oldSide,
    required super.newSide,
    required this.hunks,
  });

  final List<DiffHunk> hunks;
}
