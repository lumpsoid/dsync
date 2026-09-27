import 'package:flutter/material.dart';

import '../../pop_on_escape.dart';
import '../../readable_width.dart';
import 'filters_controller.dart';
import 'filters_scope.dart';
import 'filters_view_state.dart';

/// The Filters page: what this profile leaves out of the sync (SPEC §9).
/// Widgets only, per the page role in `app_scope.dart` — every count is a
/// string the controller rendered, and every verdict is a case it decided.
///
/// **The page answers three questions, in this order, top to bottom.**
/// *Which rules do we have* — the chips, each with what it removes.
/// *Which folder are we working on* — the path bar and the listing under
/// it, the real folder with its real contents. *What would sync* — the
/// counted summary between them, against the button that counts it. The
/// listing takes the room that is left because it is the part the user
/// works in: rules are made by pointing at rows in it.
///
/// **Nothing here is saved.** The page is a field editor for the Run setup
/// form that pushed it: [onDone] hands back the rule list as it now
/// stands, and that form is what writes it onto the profile. Popping with
/// the system back gesture goes through the same callback, so there is no
/// path out that silently drops an edit — and no Save button either, for a
/// screen where every edit is already applied to what is on screen.
class FiltersPage extends StatefulWidget {
  const FiltersPage({super.key, required this.args, required this.onDone});

  /// The folder to filter and the rules the form holds.
  final FiltersArgs args;

  /// Called as the page leaves, with the rules as they now stand.
  final void Function(List<String> ignorePatterns) onDone;

  @override
  State<FiltersPage> createState() => _FiltersPageState();
}

class _FiltersPageState extends State<FiltersPage> {
  final FiltersController _controller = filtersScope.controller;

  @override
  void initState() {
    super.initState();
    _controller.open(widget.args);
  }

  @override
  Widget build(BuildContext context) {
    return PopOnEscape(
      child: PopScope(
        // The result travels on the way out rather than from a Save button:
        // every edit is already live on this screen, so a button that
        // "applied" them would be asking the user to confirm what they can
        // already see.
        canPop: true,
        onPopInvokedWithResult: (didPop, _) {
          if (didPop) widget.onDone(_controller.state.rules);
        },
        child: Scaffold(
          appBar: AppBar(
            title: const Text('Filters'),
            bottom: PreferredSize(
              preferredSize: const Size.fromHeight(24),
              child: ListenableBuilder(
                listenable: _controller.state,
                builder: (context, _) => Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      _controller.state.rootPath,
                      key: const Key('filters-root-path'),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ),
                ),
              ),
            ),
          ),
          body: ListenableBuilder(
            listenable: _controller.state,
            builder: (context, _) => Column(
              children: [
                ReadableColumn(
                  width: ReadableWidth.list,
                  child: _RulesSection(
                    controller: _controller,
                    onAdd: () => _addRule(context),
                  ),
                ),
                const Divider(height: 1),
                ReadableColumn(
                  width: ReadableWidth.list,
                  child: _PreviewSection(controller: _controller),
                ),
                const Divider(height: 1),
                ReadableColumn(
                  width: ReadableWidth.list,
                  child: _PathBar(controller: _controller),
                ),
                Expanded(child: _Listing(controller: _controller)),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// The advanced entry: a pattern typed by hand, for the rule no row can
  /// be pointed at. Refused patterns stay in the dialog with the reason —
  /// closing over a rejected rule would look like it was accepted.
  Future<void> _addRule(BuildContext context) async {
    await showDialog<void>(
      context: context,
      builder: (context) => _AddRuleDialog(controller: _controller),
    );
  }
}

/// The rules, as chips that carry what each one removes.
///
/// Chips rather than a list: a rule is one short string, the set of them
/// is usually small, and a full-width row each would push the folder
/// listing — the part of this page the user works in — off the screen.
/// The count rides on the chip because "this rule removes nothing" is the
/// fact that catches a typo, and it has to be next to the rule it is
/// about.
class _RulesSection extends StatelessWidget {
  const _RulesSection({required this.controller, required this.onAdd});

  final FiltersController controller;
  final VoidCallback onAdd;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final rows = controller.state.ruleRows;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  rows.isEmpty ? 'Rules' : 'Rules (${rows.length})',
                  style: theme.textTheme.labelLarge,
                ),
              ),
              TextButton.icon(
                key: const Key('filters-add-rule'),
                onPressed: onAdd,
                icon: const Icon(Icons.add, size: 18),
                label: const Text('Add rule'),
              ),
            ],
          ),
          if (rows.isEmpty)
            Text(
              'No rules — everything in this folder syncs. Exclude something '
              'by tapping it in the list below.',
              key: const Key('filters-no-rules'),
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            )
          else
            Wrap(
              spacing: 8,
              runSpacing: 4,
              children: [
                for (final row in rows)
                  InputChip(
                    key: Key('filters-rule-${row.pattern}'),
                    label: Text(
                      row.removes == null
                          ? row.pattern
                          : '${row.pattern}  ·  ${row.removes}',
                    ),
                    onDeleted: () => controller.removeRule(row.pattern),
                    deleteButtonTooltipMessage: 'Remove this rule',
                  ),
              ],
            ),
        ],
      ),
    );
  }
}

/// The counted summary, and the button that counts it.
///
/// The button is the whole of the idle state: counting walks the folder,
/// which is seconds on a phone's storage, so it happens when it is asked
/// for. After a rule changes, the numbers stay on screen — they are the
/// last true answer — with the line that says they are no longer about the
/// rules above them.
class _PreviewSection extends StatelessWidget {
  const _PreviewSection({required this.controller});

  final FiltersController controller;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
      child: switch (controller.state.preview) {
        FiltersPreviewIdle() => Row(
          children: [
            Expanded(
              child: Text(
                'Count how much these rules keep and drop.',
                style: theme.textTheme.bodyMedium,
              ),
            ),
            FilledButton.tonal(
              key: const Key('filters-preview'),
              onPressed: controller.runPreview,
              child: const Text('Preview'),
            ),
          ],
        ),
        FiltersPreviewRunning() => Row(
          children: [
            const SizedBox(
              height: 16,
              width: 16,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                semanticsLabel: 'Counting what syncs',
              ),
            ),
            const SizedBox(width: 12),
            Text('Counting…', style: theme.textTheme.bodyMedium),
          ],
        ),
        FiltersPreviewReady(
          :final syncing,
          :final excluded,
          :final unreadable,
          :final stale,
        ) =>
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        _Amount(
                          key: const Key('filters-syncing'),
                          icon: Icons.sync,
                          label: '$syncing will sync',
                          colour: theme.colorScheme.primary,
                        ),
                        const SizedBox(height: 2),
                        _Amount(
                          key: const Key('filters-excluded'),
                          icon: Icons.block,
                          label: '$excluded excluded',
                          colour: theme.colorScheme.onSurfaceVariant,
                        ),
                      ],
                    ),
                  ),
                  TextButton(
                    key: const Key('filters-preview-again'),
                    onPressed: controller.runPreview,
                    child: Text(stale ? 'Count again' : 'Refresh'),
                  ),
                ],
              ),
              if (stale)
                Text(
                  'Counted before the last rule change.',
                  key: const Key('filters-preview-stale'),
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.tertiary,
                  ),
                ),
              if (unreadable != null)
                Text(
                  unreadable,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
            ],
          ),
        FiltersPreviewFailed(:final message) => Row(
          children: [
            Expanded(
              child: Text(
                message,
                key: const Key('filters-preview-failed'),
                style: TextStyle(color: theme.colorScheme.error),
              ),
            ),
            TextButton(
              onPressed: controller.runPreview,
              child: const Text('Try again'),
            ),
          ],
        ),
      },
    );
  }
}

/// One figure of the summary: an icon, then the line.
class _Amount extends StatelessWidget {
  const _Amount({
    super.key,
    required this.icon,
    required this.label,
    required this.colour,
  });

  final IconData icon;
  final String label;
  final Color colour;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(icon, size: 16, color: colour),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            label,
            style: Theme.of(context).textTheme.titleSmall
                ?.copyWith(color: colour),
          ),
        ),
      ],
    );
  }
}

/// Where the listing is, as a row of tappable segments.
///
/// The root is its own segment, named for the folder rather than shown as
/// its whole path — that path is already in the app bar, and repeating it
/// here would take the width the segments need. Tapping a segment goes
/// back to it, which is the only way up as well: an "up" button and a
/// breadcrumb are the same control drawn twice.
class _PathBar extends StatelessWidget {
  const _PathBar({required this.controller});

  final FiltersController controller;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final folder = controller.state.folder;
    final path = folder is FiltersFolderListed ? folder.path : '';
    final segments = path.isEmpty ? const <String>[] : path.split('/');
    return SizedBox(
      height: 40,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 8),
        children: [
          TextButton(
            key: const Key('filters-crumb-root'),
            onPressed: () => controller.openFolder(''),
            child: const Text('This folder'),
          ),
          for (var i = 0; i < segments.length; i++) ...[
            Icon(
              Icons.chevron_right,
              size: 16,
              color: theme.colorScheme.onSurfaceVariant,
            ),
            TextButton(
              key: Key('filters-crumb-${segments.take(i + 1).join('/')}'),
              onPressed: () =>
                  controller.openFolder(segments.take(i + 1).join('/')),
              child: Text(segments[i]),
            ),
          ],
        ],
      ),
    );
  }
}

/// The folder's contents: what is in the sync, what a rule keeps out, and
/// the way to change either.
class _Listing extends StatelessWidget {
  const _Listing({required this.controller});

  final FiltersController controller;

  @override
  Widget build(BuildContext context) {
    return switch (controller.state.folder) {
      FiltersFolderLoading() => const Center(
        child: CircularProgressIndicator(semanticsLabel: 'Opening the folder'),
      ),
      FiltersFolderFailed(:final message) => ReadableColumn(
        width: ReadableWidth.list,
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            message,
            key: const Key('filters-folder-failed'),
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
        ),
      ),
      FiltersFolderListed(:final entries) when entries.isEmpty =>
        const ReadableColumn(
          width: ReadableWidth.list,
          child: Padding(
            padding: EdgeInsets.all(24),
            child: Text(
              'This folder is empty.',
              key: Key('filters-folder-empty'),
            ),
          ),
        ),
      FiltersFolderListed(:final entries) => ReadableScrollPadding(
        width: ReadableWidth.list,
        padding: null,
        builder: (context, padding) => ListView(
          padding: padding,
          children: [
            for (final entry in entries)
              _EntryTile(controller: controller, entry: entry),
          ],
        ),
      ),
    };
  }
}

/// One row of the listing: what it is, whether it syncs, and — behind the
/// trailing button — what can be done about it.
///
/// The verdict is drawn as well as written: an excluded row is dimmed and
/// says which rule did it, so a folder that is out of the sync is visibly
/// out while scrolling, rather than something to be read for.
class _EntryTile extends StatelessWidget {
  const _EntryTile({required this.controller, required this.entry});

  final FiltersController controller;
  final FilterEntryRow entry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final excluded = entry.status is FilterEntryExcluded;
    final quiet = theme.colorScheme.onSurfaceVariant;
    return ListTile(
      key: Key('filters-entry-${entry.path}'),
      leading: Icon(
        entry.isFolder
            ? Icons.folder_outlined
            : entry.status is FilterEntryUncarried
            ? Icons.link_off
            : Icons.insert_drive_file_outlined,
        color: excluded ? quiet : null,
      ),
      title: Text(
        entry.name,
        overflow: TextOverflow.ellipsis,
        style: excluded
            ? TextStyle(
                color: quiet,
                decoration: TextDecoration.lineThrough,
                decorationColor: quiet,
              )
            : null,
      ),
      subtitle: Text(
        switch (entry.status) {
          FilterEntrySyncs() => entry.detail ?? 'Syncs',
          FilterEntryExcluded(:final pattern) =>
            entry.detail == null
                ? 'Excluded by $pattern'
                : '${entry.detail} · excluded by $pattern',
          FilterEntryUncarried(:final reason) => reason,
        },
        style: theme.textTheme.bodySmall?.copyWith(color: quiet),
        overflow: TextOverflow.ellipsis,
      ),
      onTap: entry.isFolder ? () => controller.openFolder(entry.path) : null,
      trailing: _EntryMenu(controller: controller, entry: entry),
    );
  }
}

/// The actions on a row: exclude it by name, exclude this one only, or —
/// when a rule is already keeping it out — drop that rule.
///
/// A menu rather than a swipe or a checkbox: "exclude everywhere" and
/// "exclude this one" are genuinely different rules, and a control with
/// one gesture would have to guess which the user meant. A row that a rule
/// already covers offers the way back, so an excluded folder is not a dead
/// end the user has to go find the rule for.
class _EntryMenu extends StatelessWidget {
  const _EntryMenu({required this.controller, required this.entry});

  final FiltersController controller;
  final FilterEntryRow entry;

  @override
  Widget build(BuildContext context) {
    return switch (entry.status) {
      FilterEntryUncarried() => const SizedBox.shrink(),
      FilterEntryExcluded(:final pattern) => TextButton(
        key: Key('filters-include-${entry.path}'),
        onPressed: () => controller.removeRule(pattern),
        child: const Text('Include'),
      ),
      FilterEntrySyncs() => PopupMenuButton<_EntryAction>(
        key: Key('filters-menu-${entry.path}'),
        icon: const Icon(Icons.more_vert),
        tooltip: 'Exclude ${entry.name}',
        onSelected: (action) => switch (action) {
          _EntryAction.excludeEverywhere => controller.excludeEverywhere(
            entry.name,
          ),
          _EntryAction.excludeThisOne => controller.excludeExactly(entry.path),
        },
        itemBuilder: (context) => [
          PopupMenuItem(
            value: _EntryAction.excludeEverywhere,
            child: Text("Exclude every '${entry.name}'"),
          ),
          PopupMenuItem(
            value: _EntryAction.excludeThisOne,
            child: Text(
              'Exclude only this ${entry.isFolder ? 'folder' : 'file'}',
            ),
          ),
        ],
      ),
    };
  }
}

/// The two rules a row can be turned into.
enum _EntryAction { excludeEverywhere, excludeThisOne }

/// The typed pattern, with the syntax SPEC §9 offers spelled out and a few
/// patterns that can be tapped instead of typed.
///
/// The suggestions are there because the common rules are the same on
/// every device — caches, thumbnails, hidden files — and a user who taps
/// one has also just been shown what the syntax looks like on a real
/// example.
class _AddRuleDialog extends StatefulWidget {
  const _AddRuleDialog({required this.controller});

  final FiltersController controller;

  @override
  State<_AddRuleDialog> createState() => _AddRuleDialogState();
}

class _AddRuleDialogState extends State<_AddRuleDialog> {
  final _pattern = TextEditingController();

  @override
  void dispose() {
    _pattern.dispose();
    super.dispose();
  }

  /// Adds what is typed and closes — unless the controller refused it, in
  /// which case the dialog stays open showing why.
  Future<void> _add() async {
    await widget.controller.addPattern(_pattern.text);
    if (!mounted) return;
    if (widget.controller.state.addError == null) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Add a rule'),
      content: ListenableBuilder(
        listenable: widget.controller.state,
        builder: (context, _) => Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              key: const Key('filters-pattern'),
              controller: _pattern,
              autofocus: true,
              onSubmitted: (_) => _add(),
              decoration: InputDecoration(
                labelText: 'Pattern',
                hintText: '**/*.tmp',
                helperText:
                    '* within one folder, ** across folders, ? one character.',
                helperMaxLines: 2,
                errorText: widget.controller.state.addError,
                errorMaxLines: 4,
              ),
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              children: [
                for (final suggestion in _suggestions)
                  ActionChip(
                    key: Key('filters-suggestion-$suggestion'),
                    label: Text(suggestion),
                    onPressed: () => _pattern.text = suggestion,
                  ),
              ],
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: Navigator.of(context).pop,
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const Key('filters-pattern-add'),
          onPressed: _add,
          child: const Text('Add'),
        ),
      ],
    );
  }
}

/// Patterns common enough to be worth a tap: hidden files, the temp files
/// every editor leaves, and the two caches that dominate a phone's DCIM
/// tree.
const _suggestions = ['**/.*', '**/*.tmp', '**/.thumbnails', '**/cache'];
