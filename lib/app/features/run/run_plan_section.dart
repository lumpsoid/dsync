import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../core_link/models/action_choice.dart';
import '../../format_bytes.dart';
import '../../format_count.dart';
import '../../format_path.dart';
import 'run_layout.dart';
import 'run_review_cursor.dart';
import 'run_review_keyboard.dart';
import 'run_view_state.dart';

/// The plan groups in the order the page shows them, each with its title.
const _planGroups = [
  (group: SyncRunPlanGroup.toDevice, title: 'To the remote'),
  (group: SyncRunPlanGroup.toThisDevice, title: 'To this device'),
  (group: SyncRunPlanGroup.deletions, title: 'Deletions'),
  (group: SyncRunPlanGroup.recordOnly, title: 'Record only'),
];

/// Whether [group] sits behind a disclosure: every group while [applying]
/// — the rows are then a record, not a question — and
/// [SyncRunPlanGroup.recordOnly] always.
bool _collapses(SyncRunPlanGroup group, {required bool applying}) =>
    applying || group == SyncRunPlanGroup.recordOnly;

/// The rows the review's cursor walks, in the order the page shows them:
/// the conflicts, then each plan group that is on the page — a group
/// behind a closed disclosure has no rows on it. Worked out here, beside
/// the group order and the disclosure rule [RunPlanSection] builds from,
/// so the cursor and the page cannot disagree about what is shown.
ReviewOrder reviewOrder(SyncRunViewState state, PlanDisclosures disclosures) {
  final applying = state.phase is SyncRunApplying;
  final sections = state.planSections;
  return ReviewOrder(
    conflicts: state.conflicts.length,
    actionRuns: [
      for (final (:group, title: _) in _planGroups)
        if (!_collapses(group, applying: applying) || disclosures.isOpen(group))
          sections[group]!.indexes,
    ],
  );
}

/// Which of the plan's groups are open, for the ones that sit behind a
/// disclosure — all closed to begin with.
///
/// The page's, not each group's own widget state: the review's cursor
/// walks the rows that are shown, so it has to know which groups are open
/// ([reviewOrder]). One cell per group, so opening one rebuilds that
/// group's section and not its neighbours' rows.
class PlanDisclosures {
  final List<ValueNotifier<bool>> _open = [
    for (final _ in SyncRunPlanGroup.values) ValueNotifier(false),
  ];

  ValueListenable<bool> of(SyncRunPlanGroup group) => _open[group.index];

  bool isOpen(SyncRunPlanGroup group) => _open[group.index].value;

  void toggle(SyncRunPlanGroup group) {
    final cell = _open[group.index];
    cell.value = !cell.value;
  }

  void dispose() {
    for (final cell in _open) {
      cell.dispose();
    }
  }
}

/// The plan, grouped by direction (Design C.5): a lazy sliver list per
/// [SyncRunPlanGroup], in the fixed order [SyncRunPlanGroup.toDevice],
/// [SyncRunPlanGroup.toThisDevice], [SyncRunPlanGroup.deletions], then
/// [SyncRunPlanGroup.recordOnly] last — collapsed by default, since a
/// "same content, record only" row is confirmation, not something to
/// review. A group with nothing in it renders nothing at all: an empty
/// "Deletions (0)" section would be noise on every run that has none.
///
/// **Not the whole plan area.** Unresolved conflicts (`SyncRunConflictRow`)
/// keep their own pre-existing section (`run-conflicts`) above this one in
/// `run_page.dart` — they are not a [SyncRunPlanGroup], and this widget
/// does not read [SyncRunViewState.conflicts].
///
/// **The review is these same rows.** While [SyncRunAwaitingDecisions],
/// every row gets its control ([onChoose] reaches the rows) and its frame
/// for the keyboard's [cursor]; outside it the rows have neither. The
/// action groups are expanded throughout the review — they collapse only
/// while applying — so the rows under review are the rows on screen.
///
/// **Two layouts, one set of rows.** [layout] lays each row out as the
/// phone's list tile or, on a wide window, as a table row whose columns
/// (path, action, size, choice) line up down the page under a header per
/// group, so a scan down a column reads one kind of thing.
///
/// **Keys.** `run-plan` is this whole area — present iff the plan is
/// non-empty, same as the ungrouped list it replaces. Each group's own
/// rows are `run-plan-<group>` (`SyncRunPlanGroup.name`); each group's own
/// disclosure is `run-plan-disclosure-<group>`. The bare `run-plan-
/// disclosure` key — which the plan's Verification list also requires —
/// lands on whichever group is first, in the order above, to actually
/// show a disclosure right now: that depends on the phase (the three
/// action groups disclose only while [SyncRunApplying]; [recordOnly]
/// always does) and on which groups are non-empty, so it is computed
/// fresh on every build rather than pinned to one group.
class RunPlanSection extends StatelessWidget {
  const RunPlanSection(
    this.state, {
    super.key,
    required this.onChoose,
    required this.layout,
    required this.cursor,
    required this.disclosures,
  });

  final SyncRunViewState state;

  /// What a row's control calls — `SyncRunController.choose`. Handed to
  /// the rows only while the review is up.
  final void Function(int index, ActionChoice choice) onChoose;

  final RunLayout layout;

  /// The review's keyboard cursor. Handed to the rows only while the
  /// review is up, as [onChoose] is.
  final ReviewCursor cursor;

  final PlanDisclosures disclosures;

  @override
  Widget build(BuildContext context) {
    final sections = state.planSections;
    final applying = state.phase is SyncRunApplying;
    final reviewing = state.phase is SyncRunAwaitingDecisions;
    final onChoose = reviewing ? this.onChoose : null;
    final cursor = reviewing ? this.cursor : null;

    var firstDisclosureTaken = false;
    final slivers = <Widget>[];
    for (final (:group, :title) in _planGroups) {
      final section = sections[group]!;
      if (section.count == 0) continue;
      final collapsible = _collapses(group, applying: applying);
      final isFirstDisclosure = collapsible && !firstDisclosureTaken;
      if (isFirstDisclosure) firstDisclosureTaken = true;
      final header =
          '$title (${formatCount(section.count)}'
          '${section.bytes > 0 ? ', ${formatBytes(section.bytes)}' : ''})';
      slivers.add(
        _PlanGroupSection(
          key: ValueKey(group),
          state: state,
          group: group,
          section: section,
          title: header,
          collapsible: collapsible,
          onChoose: onChoose,
          cursor: cursor,
          layout: layout,
          disclosures: disclosures,
          disclosureKey: isFirstDisclosure
              ? const Key('run-plan-disclosure')
              : Key('run-plan-disclosure-${group.name}'),
        ),
      );
    }
    return SliverMainAxisGroup(key: const Key('run-plan'), slivers: slivers);
  }
}

/// One [SyncRunPlanGroup]'s section: its header (with the group's own
/// count and bytes) and its rows, built lazily — under a row of column
/// names in the table layout. [collapsible] groups sit behind a
/// disclosure that starts closed; the others are a plain header and list,
/// exactly as the single ungrouped section used to be outside
/// [SyncRunApplying].
///
/// Whether it is open is [disclosures]' — see there — and this follows
/// its own group's cell alone. The disclosure is an [InkWell]: a Tab stop
/// that Enter and Space open and close, under a click cursor.
class _PlanGroupSection extends StatelessWidget {
  const _PlanGroupSection({
    required super.key,
    required this.state,
    required this.group,
    required this.section,
    required this.title,
    required this.collapsible,
    required this.onChoose,
    required this.cursor,
    required this.layout,
    required this.disclosures,
    required this.disclosureKey,
  });

  final SyncRunViewState state;
  final SyncRunPlanGroup group;
  final SyncRunPlanSection section;
  final String title;
  final bool collapsible;
  final void Function(int index, ActionChoice choice)? onChoose;
  final ReviewCursor? cursor;
  final RunLayout layout;
  final PlanDisclosures disclosures;
  final Key disclosureKey;

  @override
  Widget build(BuildContext context) {
    Widget row(BuildContext context, int i) {
      final position = section.indexes[i];
      final planRow = RunPlanRow(
        state: state,
        row: state.plan[position],
        onChoose: onChoose,
        layout: layout,
      );
      final cursor = this.cursor;
      if (cursor == null) return planRow;
      return ReviewRowFrame(
        cursor: cursor,
        target: ActionTarget(position),
        child: planRow,
      );
    }

    final listKey = Key('run-plan-${group.name}');
    final (columns, extent) = switch (layout) {
      RunLayout.list => (null, null),
      RunLayout.table => (
        _PlanTableHeader(choosing: onChoose != null),
        _PlanTableColumns.rowExtent(context),
      ),
    };
    if (!collapsible) {
      return RunListSection(
        sectionKey: listKey,
        title: title,
        header: columns,
        itemExtent: extent,
        itemCount: section.count,
        itemBuilder: row,
      );
    }
    return ValueListenableBuilder<bool>(
      valueListenable: disclosures.of(group),
      builder: (context, open, _) => SliverPadding(
        padding: const EdgeInsets.only(bottom: 16),
        sliver: SliverMainAxisGroup(
          slivers: [
            SliverToBoxAdapter(
              child: InkWell(
                key: disclosureKey,
                mouseCursor: SystemMouseCursors.click,
                onTap: () => disclosures.toggle(group),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        title,
                        style: Theme.of(context).textTheme.titleSmall,
                      ),
                    ),
                    Icon(open ? Icons.expand_less : Icons.expand_more),
                  ],
                ),
              ),
            ),
            if (open && columns != null) SliverToBoxAdapter(child: columns),
            if (open)
              _rowList(
                key: listKey,
                itemExtent: extent,
                itemCount: section.count,
                itemBuilder: row,
              ),
          ],
        ),
      ),
    );
  }
}

/// One planned action, grouped (Design C.5): the path split into a dim
/// parent and a bold leaf ([PathLabel]) so the part that tells two rows
/// apart is the part that reads loudest, the group's own direction glyph,
/// and the row's own result icon once [SyncRunViewState.resultCell] has
/// one for it. Follows only that cell and its own choice's
/// ([SyncRunViewState.actionDecisionCell]) — see the view state's class
/// doc comment and the section above — so applying action N, or a tap on
/// row N's control, repaints row N and nothing else in the group.
///
/// While the review is up ([onChoose] set) the row holds its control: as
/// planned, reversed where the plan offers a reverse, or skipped. What
/// the current choice will do is said literally: a reversed row shows the
/// reverse's own words and size, never the planned ones, and that stays
/// true after the review closes.
///
/// [layout] is where those parts go. [RunLayout.list] is a list tile:
/// the action and size are its subtitle, the control its trailing.
/// [RunLayout.table] gives each its own column ([_PlanTableColumns]), so
/// the actions, the sizes and the controls each line up down the page.
class RunPlanRow extends StatelessWidget {
  const RunPlanRow({
    super.key,
    required this.state,
    required this.row,
    required this.onChoose,
    required this.layout,
  });

  final SyncRunViewState state;
  final SyncRunPlanRow row;

  /// `null` outside the review: no control.
  final void Function(int index, ActionChoice choice)? onChoose;

  final RunLayout layout;

  @override
  Widget build(BuildContext context) {
    final label = PathLabel.stacked(row.path);
    return ValueListenableBuilder<SyncRunResultRow?>(
      valueListenable: state.resultCell(row.path),
      builder: (context, result, _) => ValueListenableBuilder<ActionChoice>(
        valueListenable: state.actionDecisionCell(row),
        builder: (context, choice, _) => switch (layout) {
          RunLayout.list => _listRow(context, label, result, choice),
          RunLayout.table => _tableRow(context, label, result, choice),
        },
      ),
    );
  }

  Widget _listRow(
    BuildContext context,
    PathLabel label,
    SyncRunResultRow? result,
    ActionChoice choice,
  ) {
    final theme = Theme.of(context);
    final dim = theme.colorScheme.outline;
    final skipped = choice == ActionChoice.skipped;
    final onChoose = this.onChoose;
    return ListTile(
      contentPadding: EdgeInsets.zero,
      dense: true,
      titleAlignment: ListTileTitleAlignment.top,
      leading: _resultIcon(result, theme),
      // The name wraps rather than ellipsising: the leaf is what
      // tells two rows apart, so it is never the part cut. A
      // skipped row is struck through and dimmed in place — no
      // line appears or goes, so a tap never moves the row.
      title: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 2, right: 6),
            child: Icon(_groupIcon(row.group), size: 14, color: dim),
          ),
          Expanded(
            child: _leaf(label, skipped: skipped, dim: dim, maxLines: null),
          ),
        ],
      ),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (label.parent.isNotEmpty) _parent(label, dim: dim),
          _detail(result, choice, theme),
        ],
      ),
      trailing: onChoose == null
          ? null
          : _ActionChoiceControl(
              key: Key('decision-${row.path}'),
              choice: choice,
              reversible: row.reversal != null,
              showKeys: false,
              onChoose: (choice) => onChoose(row.index, choice),
            ),
    );
  }

  /// The table's row: the list row's parts, each in its own column. The
  /// path cell is the list row's title and first subtitle line, stacked
  /// the same way, so a leaf reads loudest in the same place either way.
  ///
  /// **One line each, unlike the list row.** Every table row is one height
  /// ([_PlanTableColumns.rowExtent]) — what lets a jump anywhere in a
  /// large plan cost only the rows it lands on (`_rowList`) — so the leaf
  /// gets one line where the list row lets it wrap. The path column is
  /// ~500px wide at the table's breakpoint, which holds all but the
  /// rarest leaf whole; one longer than that is cut at its end, and the
  /// whole path is the cell's tooltip.
  Widget _tableRow(
    BuildContext context,
    PathLabel label,
    SyncRunResultRow? result,
    ActionChoice choice,
  ) {
    final theme = Theme.of(context);
    final dim = theme.colorScheme.outline;
    final skipped = choice == ActionChoice.skipped;
    final onChoose = this.onChoose;
    final (words, bytes) = _does(choice);
    final muted = skipped ? TextStyle(color: dim) : null;
    return _PlanTableColumns(
      leading: _resultIcon(result, theme),
      path: Tooltip(
        message: row.path,
        waitDuration: const Duration(milliseconds: 600),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.only(top: 2, right: 6),
              child: Icon(_groupIcon(row.group), size: 14, color: dim),
            ),
            Expanded(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _leaf(label, skipped: skipped, dim: dim, maxLines: 1),
                  if (label.parent.isNotEmpty) _parent(label, dim: dim),
                ],
              ),
            ),
          ],
        ),
      ),
      // A failure takes the action's and the size's place, as it takes
      // the list row's detail line.
      action: switch (result?.error) {
        final error? => Text(
          error,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(color: theme.colorScheme.error),
        ),
        null => Text(
          words,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: muted,
        ),
      },
      size: Text(
        result?.error == null && bytes > 0 ? formatBytes(bytes) : '',
        maxLines: 1,
        textAlign: TextAlign.end,
        // Tabular figures, so the digits line up down the column.
        style: TextStyle(
          color: muted?.color,
          fontFeatures: const [FontFeature.tabularFigures()],
        ),
      ),
      choice: onChoose == null
          ? null
          : _ActionChoiceControl(
              key: Key('decision-${row.path}'),
              choice: choice,
              reversible: row.reversal != null,
              showKeys: true,
              onChoose: (choice) => onChoose(row.index, choice),
            ),
    );
  }

  /// The leaf, bold. In the list it wraps ([maxLines] `null`) rather than
  /// ellipsising — it is what tells two rows apart; the table holds it to
  /// one line (see [_tableRow]). Skipped strikes it through and dims it in
  /// place.
  static Widget _leaf(
    PathLabel label, {
    required bool skipped,
    required Color dim,
    required int? maxLines,
  }) => Text(
    label.leaf,
    maxLines: maxLines,
    overflow: maxLines == null ? null : TextOverflow.ellipsis,
    style: TextStyle(
      fontWeight: FontWeight.bold,
      decoration: skipped ? TextDecoration.lineThrough : null,
      color: skipped ? dim : null,
    ),
  );

  static Widget _parent(PathLabel label, {required Color dim}) => Text(
    label.parent,
    maxLines: 1,
    overflow: TextOverflow.ellipsis,
    style: TextStyle(color: dim),
  );

  /// What [choice] makes this row do, in words, and the bytes it moves:
  /// the reverse's own once reversed, the plan's otherwise — skipped keeps
  /// the planned words, dimmed where they are drawn.
  (String, int) _does(ActionChoice choice) => switch ((choice, row.reversal)) {
    (ActionChoice.reversed, final reversal?) => (
      reversal.action,
      reversal.bytes,
    ),
    _ => (row.action, row.bytes),
  };

  /// The row's one line of what it does, always present so every choice
  /// keeps the row the same height: the planned action and its size, the
  /// reverse's own words and size once reversed, the error once failed.
  /// Skipped keeps the planned words, dimmed — the struck-through name and
  /// the control say it is left out.
  Widget _detail(
    SyncRunResultRow? result,
    ActionChoice choice,
    ThemeData theme,
  ) {
    if (result?.error case final error?) {
      return Text(error, style: TextStyle(color: theme.colorScheme.error));
    }
    final (words, bytes) = _does(choice);
    return Text(
      bytes > 0 ? '$words · ${formatBytes(bytes)}' : words,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: choice == ActionChoice.skipped
          ? TextStyle(color: theme.colorScheme.outline)
          : null,
    );
  }
}

/// Each action choice's name: its segment's tooltip, and its word in the
/// review bar's key legend.
String actionChoiceName(ActionChoice choice) => switch (choice) {
  ActionChoice.proposed => 'As planned',
  ActionChoice.reversed => 'Reverse',
  ActionChoice.skipped => 'Skip',
};

/// A plan row's review control: as planned, reversed — offered only when
/// the row is [reversible] — or skipped. Icons rather than words so it fits
/// beside the path on a phone; each segment's tooltip is its name — and,
/// where the keyboard review is at home ([showKeys]), the key that picks
/// it — and the row's subtitle spells out what the chosen one does.
class _ActionChoiceControl extends StatelessWidget {
  const _ActionChoiceControl({
    super.key,
    required this.choice,
    required this.reversible,
    required this.showKeys,
    required this.onChoose,
  });

  final ActionChoice choice;
  final bool reversible;
  final bool showKeys;
  final ValueChanged<ActionChoice> onChoose;

  String _tooltip(ActionChoice choice) {
    final name = actionChoiceName(choice);
    return switch (actionChoiceKeys[choice]) {
      final key? when showKeys => '$name (${key.keyLabel})',
      _ => name,
    };
  }

  @override
  Widget build(BuildContext context) {
    return SegmentedButton<ActionChoice>(
      showSelectedIcon: false,
      style: const ButtonStyle(visualDensity: VisualDensity.compact),
      segments: [
        ButtonSegment(
          value: ActionChoice.proposed,
          icon: const Icon(Icons.check),
          tooltip: _tooltip(ActionChoice.proposed),
        ),
        if (reversible)
          ButtonSegment(
            value: ActionChoice.reversed,
            icon: const Icon(Icons.swap_horiz),
            tooltip: _tooltip(ActionChoice.reversed),
          ),
        ButtonSegment(
          value: ActionChoice.skipped,
          icon: const Icon(Icons.block),
          tooltip: _tooltip(ActionChoice.skipped),
        ),
      ],
      selected: {choice},
      onSelectionChanged: (selected) => onChoose(selected.single),
    );
  }
}

/// The plan table's columns — one definition for the column names and
/// every row, so the two cannot drift out of line.
///
/// The fixed columns are sized to what they hold: a result icon, a size
/// ("1,023.9 MiB"), and the widest control (three segments). The path and
/// the action share what is left, the path the larger part: it is what
/// tells two rows apart, and an action is one of a few fixed phrases that
/// may take a second line. [choice] is `null` outside the review, and its
/// column goes with it.
///
/// Every row is [rowExtent] tall: two lines of the body text at the
/// user's text scale — a leaf over its parent — or the control's tap
/// target if that is taller, with a little air, so a row never clips at
/// any text size.
class _PlanTableColumns extends StatelessWidget {
  const _PlanTableColumns({
    required this.leading,
    required this.path,
    required this.action,
    required this.size,
    required this.choice,
  });

  static const _leadingWidth = 36.0;
  static const _sizeWidth = 96.0;
  static const _choiceWidth = 168.0;
  static const _gap = 16.0;
  static const _pathFlex = 3;
  static const _actionFlex = 2;

  /// The tallest a choice control gets: Material's minimum tap target,
  /// which it is padded to where the platform is touch-first.
  static const _controlHeight = kMinInteractiveDimension;
  static const _rowPadding = 6.0;

  /// The height of every table row, for [context]'s text style and scale.
  static double rowExtent(BuildContext context) {
    final painter = TextPainter(
      text: TextSpan(
        text: 'Ag',
        style: DefaultTextStyle.of(context).style
            .copyWith(fontWeight: FontWeight.bold),
      ),
      textScaler: MediaQuery.textScalerOf(context),
      textDirection: TextDirection.ltr,
    )..layout();
    final line = painter.height;
    painter.dispose();
    return math.max(2 * line, _controlHeight) + 2 * _rowPadding;
  }

  final Widget leading;
  final Widget path;
  final Widget action;
  final Widget size;
  final Widget? choice;

  @override
  Widget build(BuildContext context) {
    final choice = this.choice;
    return Row(
      children: [
        SizedBox(
          width: _leadingWidth,
          child: Align(alignment: Alignment.centerLeft, child: leading),
        ),
        Expanded(flex: _pathFlex, child: path),
        const SizedBox(width: _gap),
        Expanded(flex: _actionFlex, child: action),
        const SizedBox(width: _gap),
        SizedBox(
          width: _sizeWidth,
          child: Align(alignment: Alignment.centerRight, child: size),
        ),
        if (choice != null) ...[
          const SizedBox(width: _gap),
          SizedBox(
            width: _choiceWidth,
            child: Align(alignment: Alignment.centerRight, child: choice),
          ),
        ],
      ],
    );
  }
}

/// A plan group's column names, over its first row and ruled off from
/// it: what a scan down each column is reading. "Choice" only while the
/// review is up ([choosing]), when the rows have that column.
class _PlanTableHeader extends StatelessWidget {
  const _PlanTableHeader({required this.choosing});

  final bool choosing;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final style = theme.textTheme.labelMedium?.copyWith(
      color: theme.colorScheme.outline,
    );
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Column(
        children: [
          _PlanTableColumns(
            leading: const SizedBox.shrink(),
            path: Text('Path', style: style),
            action: Text('Action', style: style),
            size: Text('Size', style: style),
            choice: choosing ? Text('Choice', style: style) : null,
          ),
          const SizedBox(height: 4),
          const Divider(height: 1),
        ],
      ),
    );
  }
}

/// The leading icon of a plan row: nothing reported yet, applied, or
/// failed. Distinct from the stage strip's icons (`check_circle`/
/// `circle`/`circle_outlined`) so the two never read as the same mark.
Widget _resultIcon(SyncRunResultRow? result, ThemeData theme) {
  if (result == null) return const Icon(Icons.radio_button_unchecked);
  if (result.error == null) return const Icon(Icons.check_circle_outline);
  return Icon(Icons.error_outline, color: theme.colorScheme.error);
}

/// The small mark beside a row's path that says which [SyncRunPlanGroup]
/// it is in — a group already said by the section it sits under, repeated
/// here because a row can be selected (Phase 7) and read on its own.
IconData _groupIcon(SyncRunPlanGroup group) => switch (group) {
  SyncRunPlanGroup.toDevice => Icons.arrow_upward,
  SyncRunPlanGroup.toThisDevice => Icons.arrow_downward,
  SyncRunPlanGroup.deletions => Icons.delete_outline,
  SyncRunPlanGroup.recordOnly => Icons.fact_check_outlined,
};

/// One titled section of path rows: the title as a sliver of its own, so
/// it is on the page whatever part of the section's list the viewport
/// holds, then the rows built lazily — the rows the viewport holds are
/// the rows that exist. [sectionKey] is on the row list: "this section is
/// shown at all" stays assertable while its rows come and go with the
/// scroll. [header], where there is one, sits between the title and the
/// rows — the plan table's column names.
///
/// Public rather than file-private: `run_page.dart`'s unreadable, symlink
/// and conflict lists use it too, and a title-plus-lazy-list section is
/// exactly the same shape for all of them.
class RunListSection extends StatelessWidget {
  const RunListSection({
    super.key,
    required this.sectionKey,
    required this.title,
    required this.header,
    required this.itemExtent,
    required this.itemCount,
    required this.itemBuilder,
  });

  final Key sectionKey;
  final String title;
  final Widget? header;

  /// Every row's height, where the rows share one — see [_rowList].
  final double? itemExtent;

  final int itemCount;
  final IndexedWidgetBuilder itemBuilder;

  @override
  Widget build(BuildContext context) {
    final header = this.header;
    return SliverPadding(
      // The section's trailing space, which was the padding of the box that
      // used to hold the title and the rows together.
      padding: const EdgeInsets.only(bottom: 16),
      sliver: SliverMainAxisGroup(
        slivers: [
          SliverToBoxAdapter(
            child: Text(title, style: Theme.of(context).textTheme.titleSmall),
          ),
          if (header != null) SliverToBoxAdapter(child: header),
          _rowList(
            key: sectionKey,
            itemExtent: itemExtent,
            itemCount: itemCount,
            itemBuilder: itemBuilder,
          ),
        ],
      ),
    );
  }
}

/// A lazy list of rows: of one [itemExtent] where the rows share one, of
/// whatever height each row takes otherwise.
///
/// **Why one height matters.** A list of rows of their own heights knows
/// where row N is only by laying out every row before it, so a jump far
/// back — Home in the review, the scrollbar dragged to the top — builds
/// every row in between: on a 3,000-row plan, seconds of it. Rows of one
/// height put row N at N × [itemExtent], and a jump anywhere builds only
/// the rows it lands on.
Widget _rowList({
  required Key key,
  required double? itemExtent,
  required int itemCount,
  required IndexedWidgetBuilder itemBuilder,
}) => switch (itemExtent) {
  final extent? => SliverFixedExtentList.builder(
    key: key,
    itemExtent: extent,
    itemCount: itemCount,
    itemBuilder: itemBuilder,
  ),
  null => SliverList.builder(
    key: key,
    itemCount: itemCount,
    itemBuilder: itemBuilder,
  ),
};
