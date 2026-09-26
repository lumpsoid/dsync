import 'package:flutter/material.dart';

import '../../core_link/models/action_choice.dart';
import '../../format_bytes.dart';
import '../../format_count.dart';
import '../../format_path.dart';
import 'run_view_state.dart';

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
/// every row gets its control ([onChoose] reaches the rows); outside it the
/// rows have none. The action groups are expanded throughout the review —
/// they collapse only while applying — so the rows under review are the
/// rows on screen.
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
  const RunPlanSection(this.state, {super.key, required this.onChoose});

  final SyncRunViewState state;

  /// What a row's control calls — `SyncRunController.choose`. Handed to
  /// the rows only while the review is up.
  final void Function(int index, ActionChoice choice) onChoose;

  @override
  Widget build(BuildContext context) {
    final sections = state.planSections;
    final applying = state.phase is SyncRunApplying;
    final onChoose = state.phase is SyncRunAwaitingDecisions
        ? this.onChoose
        : null;
    final groups = [
      (group: SyncRunPlanGroup.toDevice, title: 'To the remote'),
      (group: SyncRunPlanGroup.toThisDevice, title: 'To this device'),
      (group: SyncRunPlanGroup.deletions, title: 'Deletions'),
      (group: SyncRunPlanGroup.recordOnly, title: 'Record only'),
    ];

    var firstDisclosureTaken = false;
    final slivers = <Widget>[];
    for (final (:group, :title) in groups) {
      final section = sections[group]!;
      if (section.count == 0) continue;
      final collapsible = applying || group == SyncRunPlanGroup.recordOnly;
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
/// count and bytes) and its rows, built lazily. [collapsible] groups sit
/// behind a disclosure that starts closed; the others are a plain header
/// and list, exactly as the single ungrouped section used to be outside
/// [SyncRunApplying].
///
/// Expansion is this widget's own state, not the view state's — the same
/// reasoning as the section it replaces (`run_page.dart`'s old
/// `_PlanSection`): it renders no run update, and [RunPlanSection] gives
/// each group a stable [ValueKey] so a group's own open/closed state
/// survives a rebuild even as other groups come and go around it.
class _PlanGroupSection extends StatefulWidget {
  const _PlanGroupSection({
    required super.key,
    required this.state,
    required this.group,
    required this.section,
    required this.title,
    required this.collapsible,
    required this.onChoose,
    required this.disclosureKey,
  });

  final SyncRunViewState state;
  final SyncRunPlanGroup group;
  final SyncRunPlanSection section;
  final String title;
  final bool collapsible;
  final void Function(int index, ActionChoice choice)? onChoose;
  final Key disclosureKey;

  @override
  State<_PlanGroupSection> createState() => _PlanGroupSectionState();
}

class _PlanGroupSectionState extends State<_PlanGroupSection> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final state = widget.state;
    final section = widget.section;
    Widget row(BuildContext context, int i) {
      final planRow = state.plan[section.indexes[i]];
      return RunPlanRow(state: state, row: planRow, onChoose: widget.onChoose);
    }

    final listKey = Key('run-plan-${widget.group.name}');
    if (!widget.collapsible) {
      return RunListSection(
        sectionKey: listKey,
        title: widget.title,
        itemCount: section.count,
        itemBuilder: row,
      );
    }
    return SliverPadding(
      padding: const EdgeInsets.only(bottom: 16),
      sliver: SliverMainAxisGroup(
        slivers: [
          SliverToBoxAdapter(
            child: InkWell(
              key: widget.disclosureKey,
              onTap: () => setState(() => _expanded = !_expanded),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      widget.title,
                      style: Theme.of(context).textTheme.titleSmall,
                    ),
                  ),
                  Icon(_expanded ? Icons.expand_less : Icons.expand_more),
                ],
              ),
            ),
          ),
          if (_expanded)
            SliverList.builder(
              key: listKey,
              itemCount: section.count,
              itemBuilder: row,
            ),
        ],
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
/// While the review is up ([onChoose] set) `trailing` holds the row's
/// control: as planned, reversed where the plan offers a reverse, or
/// skipped. The subtitle says what the current choice will do, literally:
/// a reversed row shows the reverse's own words and size, never the
/// planned ones, and that stays true after the review closes.
class RunPlanRow extends StatelessWidget {
  const RunPlanRow({
    super.key,
    required this.state,
    required this.row,
    required this.onChoose,
  });

  final SyncRunViewState state;
  final SyncRunPlanRow row;

  /// `null` outside the review: no control.
  final void Function(int index, ActionChoice choice)? onChoose;

  @override
  Widget build(BuildContext context) {
    final label = PathLabel.stacked(row.path);
    return ValueListenableBuilder<SyncRunResultRow?>(
      valueListenable: state.resultCell(row.path),
      builder: (context, result, _) => ValueListenableBuilder<ActionChoice>(
        valueListenable: state.actionDecisionCell(row),
        builder: (context, choice, _) {
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
                  child: Text(
                    label.leaf,
                    style: TextStyle(
                      fontWeight: FontWeight.bold,
                      decoration: skipped ? TextDecoration.lineThrough : null,
                      color: skipped ? dim : null,
                    ),
                  ),
                ),
              ],
            ),
            subtitle: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (label.parent.isNotEmpty)
                  Text(
                    label.parent,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: dim),
                  ),
                _detail(result, choice, theme),
              ],
            ),
            trailing: onChoose == null
                ? null
                : _ActionChoiceControl(
                    key: Key('decision-${row.path}'),
                    choice: choice,
                    reversible: row.reversal != null,
                    onChoose: (choice) => onChoose(row.index, choice),
                  ),
          );
        },
      ),
    );
  }

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
    final (words, bytes) = switch ((choice, row.reversal)) {
      (ActionChoice.reversed, final reversal?) => (
        reversal.action,
        reversal.bytes,
      ),
      _ => (row.action, row.bytes),
    };
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

/// A plan row's review control: as planned, reversed — offered only when
/// the row is [reversible] — or skipped. Icons rather than words so it fits
/// beside the path on a phone; each segment's tooltip is its name, and the
/// row's subtitle spells out what the chosen one does.
class _ActionChoiceControl extends StatelessWidget {
  const _ActionChoiceControl({
    super.key,
    required this.choice,
    required this.reversible,
    required this.onChoose,
  });

  final ActionChoice choice;
  final bool reversible;
  final ValueChanged<ActionChoice> onChoose;

  @override
  Widget build(BuildContext context) {
    return SegmentedButton<ActionChoice>(
      showSelectedIcon: false,
      style: const ButtonStyle(visualDensity: VisualDensity.compact),
      segments: [
        const ButtonSegment(
          value: ActionChoice.proposed,
          icon: Icon(Icons.check),
          tooltip: 'As planned',
        ),
        if (reversible)
          const ButtonSegment(
            value: ActionChoice.reversed,
            icon: Icon(Icons.swap_horiz),
            tooltip: 'Reverse',
          ),
        const ButtonSegment(
          value: ActionChoice.skipped,
          icon: Icon(Icons.block),
          tooltip: 'Skip',
        ),
      ],
      selected: {choice},
      onSelectionChanged: (selected) => onChoose(selected.single),
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
/// scroll.
///
/// Public rather than file-private: `run_page.dart`'s unreadable, symlink
/// and conflict lists use it too, and a title-plus-lazy-list section is
/// exactly the same shape for all of them.
class RunListSection extends StatelessWidget {
  const RunListSection({
    super.key,
    required this.sectionKey,
    required this.title,
    required this.itemCount,
    required this.itemBuilder,
  });

  final Key sectionKey;
  final String title;
  final int itemCount;
  final IndexedWidgetBuilder itemBuilder;

  @override
  Widget build(BuildContext context) {
    return SliverPadding(
      // The section's trailing space, which was the padding of the box that
      // used to hold the title and the rows together.
      padding: const EdgeInsets.only(bottom: 16),
      sliver: SliverMainAxisGroup(
        slivers: [
          SliverToBoxAdapter(
            child: Text(title, style: Theme.of(context).textTheme.titleSmall),
          ),
          SliverList.builder(
            key: sectionKey,
            itemCount: itemCount,
            itemBuilder: itemBuilder,
          ),
        ],
      ),
    );
  }
}
