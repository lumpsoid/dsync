/// A run of changes with its context. Starts are 1-based; a side with no
/// lines in the hunk keeps the number its next line would have.
final class DiffHunk {
  const DiffHunk({
    required this.oldStart,
    required this.newStart,
    required this.blocks,
  });

  final int oldStart;
  final int newStart;
  final List<DiffBlock> blocks;
}

sealed class DiffBlock {
  const DiffBlock();
}

/// Lines both sides share.
final class SameBlock extends DiffBlock {
  const SameBlock(this.lines);

  final List<String> lines;
}

/// Lines only the old side has and lines only the new side has.
final class ChangedBlock extends DiffBlock {
  const ChangedBlock({required this.oldLines, required this.newLines});

  final List<DiffLine> oldLines;
  final List<DiffLine> newLines;
}

/// One line, in at least one span.
final class DiffLine {
  const DiffLine(this.spans);

  final List<DiffSpan> spans;
}

/// A stretch of a line; [emphasized] where it differs from the other side.
final class DiffSpan {
  const DiffSpan(this.text, {required this.emphasized});

  final String text;
  final bool emphasized;
}
