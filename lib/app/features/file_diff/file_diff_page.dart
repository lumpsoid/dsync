import 'package:flutter/material.dart';

import '../../core_link/models/diff_hunk.dart';
import '../../monospace.dart';
import '../../path_text.dart';
import '../../pop_on_escape.dart';
import 'file_diff_controller.dart';
import 'file_diff_layout.dart';
import 'file_diff_scope.dart';
import 'file_diff_view_state.dart';

/// The diff page: how one review row's two files differ. Widgets only,
/// per the page role in `app_scope.dart` — every line, number and
/// sentence is one the view state built.
///
/// **Opens at once, with what the row knows.** The path and both sides'
/// sizes are on the row already, so they head the page from the first
/// frame; under them one static line says what is being read ("Reading
/// Remote · 13 KiB…") until the comparison lands. No spinner: the line
/// names the wait, and a spinner would only say there is one.
///
/// **Laid out for the device** ([FileDiffLayout]): one column on a phone,
/// a changed block's old lines then its new; two aligned columns on a
/// wide window. Marks (`−`, `+`) go with the tints in both, so colour is
/// never the only cue.
///
/// Reads only: a side is chosen on the run review, not here.
class FileDiffPage extends StatefulWidget {
  const FileDiffPage({super.key, required this.args});

  /// The row to compare and what it already shows.
  final FileDiffArgs args;

  @override
  State<FileDiffPage> createState() => _FileDiffPageState();
}

class _FileDiffPageState extends State<FileDiffPage> {
  /// Fresh per page and disposed with it: see `FileDiffScope`.
  final FileDiffController _controller = fileDiffScope.create();

  @override
  void initState() {
    super.initState();
    _controller.open(widget.args);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final layout = FileDiffLayout.forWidth(constraints.maxWidth);
        return PopOnEscape(
          child: Scaffold(
            appBar: AppBar(
              title: ListenableBuilder(
                listenable: _controller.state,
                builder: (context, _) => PathText(
                  _controller.state.path,
                  key: const Key('file-diff-path'),
                  style: null,
                  leafStyle: null,
                ),
              ),
            ),
            body: ListenableBuilder(
              listenable: _controller.state,
              builder: (context, _) => Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _Header(state: _controller.state, layout: layout),
                  const Divider(height: 1),
                  Expanded(child: _body(context, layout)),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _body(BuildContext context, FileDiffLayout layout) {
    final style = Theme.of(context).textTheme.bodyMedium;
    Widget say(String text, Key key) => Padding(
      padding: const EdgeInsets.all(16),
      child: Text(text, key: key, style: style),
    );
    return switch (_controller.state.view) {
      FileDiffReading(:final line) => say(line, const Key('file-diff-reading')),
      FileDiffFailed(:final message) => say(
        message,
        const Key('file-diff-failed'),
      ),
      FileDiffSentence(:final sentence) => say(
        sentence,
        const Key('file-diff-sentence'),
      ),
      FileDiffText() && final text => _Lines(text: text, layout: layout),
    };
  }
}

/// Which side is old and which is new, with each side's name and size:
/// one line each in a column, or one above each column when split.
class _Header extends StatelessWidget {
  const _Header({required this.state, required this.layout});

  final FileDiffViewState state;
  final FileDiffLayout layout;

  @override
  Widget build(BuildContext context) {
    final style = Theme.of(context).textTheme.labelLarge;
    final old = Text(
      '${DiffMark.removed.sign} ${state.oldSide}',
      key: const Key('file-diff-old-side'),
      style: style,
    );
    final fresh = Text(
      '${DiffMark.added.sign} ${state.newSide}',
      key: const Key('file-diff-new-side'),
      style: style,
    );
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: switch (layout) {
        FileDiffLayout.unified => Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [old, fresh],
        ),
        FileDiffLayout.split => Row(
          children: [
            Expanded(child: old),
            Expanded(child: fresh),
          ],
        ),
      },
    );
  }
}

/// The diff's rows, built lazily: a long file's diff is thousands of rows,
/// and only a screenful is ever on it.
class _Lines extends StatelessWidget {
  const _Lines({required this.text, required this.layout});

  final FileDiffText text;
  final FileDiffLayout layout;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final style = theme.textTheme.bodySmall?.copyWith(
      fontFamily: 'monospace',
      fontFamilyFallback: monospaceFallback,
    );
    final tints = _Tints(theme.colorScheme);
    final rows = switch (layout) {
      FileDiffLayout.unified => text.unified,
      FileDiffLayout.split => text.split,
    };
    return ListView.builder(
      key: const Key('file-diff-lines'),
      itemCount: rows.length,
      itemBuilder: (context, index) => switch (rows[index]) {
        DiffGapRow() && final gap => Container(
          color: theme.colorScheme.surfaceContainerHighest,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 2),
          child: Text(
            gap.label,
            key: const Key('file-diff-gap'),
            style: style?.copyWith(color: theme.colorScheme.outline),
          ),
        ),
        UnifiedLineRow() && final row => Container(
          color: tints.line(row.mark),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _gutter(row.oldNumber, style, theme),
              _gutter(row.newNumber, style, theme),
              Expanded(child: _text(row.mark, row.spans, style, tints)),
            ],
          ),
        ),
        SplitLineRow() && final row => IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(child: _cell(row.oldCell, style, theme, tints)),
              VerticalDivider(width: 1, color: theme.dividerColor),
              Expanded(child: _cell(row.newCell, style, theme, tints)),
            ],
          ),
        ),
      },
    );
  }

  Widget _cell(
    DiffCell? cell,
    TextStyle? style,
    ThemeData theme,
    _Tints tints,
  ) {
    if (cell == null) {
      return ColoredBox(
        key: const Key('file-diff-pad'),
        color: theme.colorScheme.surfaceContainerLow,
      );
    }
    return Container(
      color: tints.line(cell.mark),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _gutter(cell.number, style, theme),
          Expanded(child: _text(cell.mark, cell.spans, style, tints)),
        ],
      ),
    );
  }

  /// A line number, right-aligned to the widest one so the column is
  /// straight; blank where the line is not on that side.
  Widget _gutter(int? number, TextStyle? style, ThemeData theme) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 6),
    child: Text(
      (number?.toString() ?? '').padLeft(text.numberWidth),
      style: style?.copyWith(color: theme.colorScheme.outline),
    ),
  );

  /// The mark and the line, its emphasized spans bold on a stronger tint.
  /// Wraps: a long line reads in full rather than off the edge.
  Widget _text(
    DiffMark mark,
    List<DiffSpan> spans,
    TextStyle? style,
    _Tints tints,
  ) => Text.rich(
    TextSpan(
      style: style,
      children: [
        TextSpan(text: '${mark.sign} '),
        for (final span in spans)
          span.emphasized
              ? TextSpan(
                  text: span.text,
                  style: TextStyle(
                    fontWeight: FontWeight.bold,
                    backgroundColor: tints.emphasis(mark),
                  ),
                )
              : TextSpan(text: span.text),
      ],
    ),
  );
}

/// The diff's colours: removed lines on the error container, added on the
/// primary container, and an emphasized stretch on a stronger shade of
/// its line's.
class _Tints {
  _Tints(this.scheme);

  final ColorScheme scheme;

  Color? line(DiffMark mark) => switch (mark) {
    DiffMark.same => null,
    DiffMark.removed => scheme.errorContainer,
    DiffMark.added => scheme.primaryContainer,
  };

  Color? emphasis(DiffMark mark) => switch (mark) {
    DiffMark.same => null,
    DiffMark.removed => scheme.error.withValues(alpha: 0.3),
    DiffMark.added => scheme.primary.withValues(alpha: 0.3),
  };
}
