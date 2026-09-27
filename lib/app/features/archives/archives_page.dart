import 'package:flutter/material.dart';

import '../../archive_row.dart';
import '../../refresh_action.dart';
import 'archives_controller.dart';
import 'archives_scope.dart';
import 'archives_view_state.dart';

/// The Archives page: what this device's sync history costs on disk, and
/// deleting it (SPEC §8.1, §8.3, §13). Widgets only, per the page role in
/// `app_scope.dart` — every row is an [ArchiveRow] of already-rendered
/// values, and the only branches here are over the sealed [ArchivesListing].
///
/// **It is called "sync history", not "archives", on screen.** The archive
/// is SPEC's word for the record of what was last propagated; what a person
/// deleting it needs to know is that it is history, that it costs this much,
/// and that losing it costs a full rescan rather than any file. The CLI
/// keeps SPEC's word (`dsync archive list`), where the reader is a person
/// who has read SPEC.
///
/// **Rows can be ticked, and the ticked ones deleted together.** Long press
/// starts it; the app bar then says how many are picked and carries the
/// delete. It exists for the middle case the other two buttons miss: three
/// dead histories out of a dozen, where deleting each in turn is four taps
/// apiece and "delete all" costs the nine that are still earning their keep.
///
/// Loads on mounting and refreshes on pull, on the app-bar [RefreshButton]
/// or on F5 ([RefreshShortcuts]), like the home list. It takes no
/// navigation callbacks: nothing leads anywhere from here.
class ArchivesPage extends StatefulWidget {
  const ArchivesPage({super.key});

  @override
  State<ArchivesPage> createState() => _ArchivesPageState();
}

class _ArchivesPageState extends State<ArchivesPage> {
  final ArchivesController _controller = archivesScope.controller;

  @override
  void initState() {
    super.initState();
    _controller.refresh();
  }

  @override
  Widget build(BuildContext context) {
    // The whole scaffold rebuilds on the view state, not just the body: the
    // app-bar action exists only over a list with rows, so it is as much a
    // reader of the listing as the body is.
    return RefreshShortcuts(
      onRefresh: _controller.refresh,
      child: ListenableBuilder(
        listenable: _controller.state,
        builder: (context, _) => _scaffold(context),
      ),
    );
  }

  Widget _scaffold(BuildContext context) {
    return Scaffold(
      appBar: _controller.state.isSelecting
          ? _selectionAppBar(context)
          : _titleAppBar(context),
      body: _ArchivesBody(controller: _controller),
    );
  }

  AppBar _titleAppBar(BuildContext context) {
    return AppBar(
      title: const Text('Sync history'),
      actions: [
        RefreshButton(
          key: const Key('archives-refresh'),
          onRefresh: _controller.refresh,
        ),
        // Only over a list that has rows: "delete everything" is not an
        // action to offer while the page is still reading, or over nothing.
        if (_controller.state.listing case ArchivesReady(:final rows)
            when rows.isNotEmpty)
          IconButton(
            key: const Key('archives-delete-all'),
            icon: const Icon(Icons.delete_sweep_outlined),
            tooltip: 'Delete all history',
            onPressed: () => _confirmDeleteAll(context, rows.length),
          ),
      ],
    );
  }

  /// The bar while rows are ticked: what is ticked, a way out that deletes
  /// nothing, and the delete. "Delete all" is gone from it on purpose —
  /// having picked three of a dozen, the button next to the count should
  /// not be the one that takes the other nine.
  AppBar _selectionAppBar(BuildContext context) {
    final count = _controller.state.selected.length;
    return AppBar(
      leading: IconButton(
        key: const Key('archives-selection-cancel'),
        icon: const Icon(Icons.close),
        tooltip: 'Stop selecting',
        onPressed: _controller.clearSelection,
      ),
      title: Text('$count selected'),
      actions: [
        IconButton(
          key: const Key('archives-delete-selected'),
          icon: const Icon(Icons.delete_outline),
          tooltip: 'Delete selected history',
          onPressed: () => _confirmDeleteSelected(context, count),
        ),
      ],
    );
  }

  Future<void> _confirmDeleteAll(BuildContext context, int count) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => _DeleteAllDialog(count: count),
    );
    if (confirmed ?? false) await _controller.deleteAll();
  }

  Future<void> _confirmDeleteSelected(BuildContext context, int count) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => _DeleteSelectedDialog(count: count),
    );
    if (confirmed ?? false) await _controller.deleteSelected();
  }
}

class _ArchivesBody extends StatelessWidget {
  const _ArchivesBody({required this.controller});

  final ArchivesController controller;

  @override
  Widget build(BuildContext context) {
    final error = controller.state.error;
    return RefreshIndicator(
      onRefresh: controller.refresh,
      child: ListView(
        // Scrollable even when short, so pull-to-refresh works on an empty
        // or one-row list.
        physics: const AlwaysScrollableScrollPhysics(),
        children: [
          if (error != null) _NoticeTile(error),
          ...switch (controller.state.listing) {
            ArchivesLoading() => const [_LoadingTile()],
            ArchivesFailed(:final message) => [_NoticeTile(message)],
            ArchivesReady(:final rows) when rows.isEmpty => const [
              _EmptyState(),
            ],
            ArchivesReady(:final rows, :final totalLabel) => [
              _TotalTile(totalLabel: totalLabel, count: rows.length),
              for (final row in rows)
                _ArchiveTile(
                  row: row,
                  isSelecting: controller.state.isSelecting,
                  isSelected: controller.state.isSelected(row.logPath),
                  onToggleSelection: () =>
                      controller.toggleSelection(row.logPath),
                  onDelete: () => _confirmDelete(context, row),
                ),
              const _Explanation(),
            ],
          },
        ],
      ),
    );
  }

  Future<void> _confirmDelete(BuildContext context, ArchiveRow row) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => _DeleteDialog(row: row),
    );
    if (confirmed ?? false) await controller.delete(row.logPath);
  }
}

/// An error line above the list — a delete refused by a run in progress, or
/// a state directory that could not be read — in the theme's error colour.
class _NoticeTile extends StatelessWidget {
  const _NoticeTile(this.message);

  final String message;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      key: const Key('archives-notice'),
      leading: Icon(
        Icons.error_outline,
        color: Theme.of(context).colorScheme.error,
      ),
      title: Text(message),
    );
  }
}

class _LoadingTile extends StatelessWidget {
  const _LoadingTile();

  @override
  Widget build(BuildContext context) {
    return const Padding(
      padding: EdgeInsets.all(32),
      child: Center(
        child: CircularProgressIndicator(
          semanticsLabel: 'Reading sync history',
        ),
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState();

  @override
  Widget build(BuildContext context) {
    return const Padding(
      padding: EdgeInsets.all(32),
      child: Text(
        'No sync history stored. The next run over any folder starts from '
        'scratch.',
        textAlign: TextAlign.center,
      ),
    );
  }
}

/// What the whole of it costs — the number this page is opened for, so it
/// sits above the rows rather than under them.
class _TotalTile extends StatelessWidget {
  const _TotalTile({required this.totalLabel, required this.count});

  final String totalLabel;
  final int count;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListTile(
      key: const Key('archives-total'),
      leading: const Icon(Icons.sd_storage_outlined),
      title: Text(totalLabel, style: theme.textTheme.titleLarge),
      subtitle: Text(
        count == 1 ? 'in 1 stored history' : 'across $count stored histories',
      ),
    );
  }
}

/// One archive. The name comes first because it is what the user recognises,
/// the device the run talks to under it — two histories of the same size
/// are told apart by the machine, not the byte count — the folder and the
/// size next because they are what the decision is made on, and the remark
/// — if any — last, in the error colour it deserves: an archive no saved
/// run points at is the one worth deleting.
///
/// The peer line is absent, not empty, when no saved run claims the
/// archive: there is no device to name then, and the remark says why.
class _ArchiveTile extends StatelessWidget {
  const _ArchiveTile({
    required this.row,
    required this.isSelecting,
    required this.isSelected,
    required this.onToggleSelection,
    required this.onDelete,
  });

  final ArchiveRow row;

  /// Whether any row on the page is ticked. While that holds, a tap ticks
  /// this row rather than doing nothing, and the per-row delete gives way to
  /// the one in the bar — two deletes on screen, one over this row and one
  /// over the selection, is a way to delete the wrong thing.
  final bool isSelecting;
  final bool isSelected;
  final VoidCallback onToggleSelection;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final note = row.note;
    final peerLine = row.peerLine;
    return ListTile(
      key: Key('archive-row-${row.logPath}'),
      selected: isSelected,
      // Long press starts selecting, the platform's own gesture for it; once
      // selecting, a plain tap is enough.
      onLongPress: onToggleSelection,
      onTap: isSelecting ? onToggleSelection : null,
      leading: isSelecting
          ? Icon(
              isSelected ? Icons.check_circle : Icons.circle_outlined,
              color: isSelected ? theme.colorScheme.primary : null,
            )
          : null,
      title: Text(row.title),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (peerLine != null) Text(peerLine),
          Text(row.location, overflow: TextOverflow.ellipsis),
          Text('${row.sizeLabel} · last written ${row.lastWritten}'),
          if (note != null)
            Text(note, style: TextStyle(color: theme.colorScheme.error)),
        ],
      ),
      isThreeLine: true,
      trailing: isSelecting
          ? null
          : IconButton(
              key: Key('archive-delete-${row.logPath}'),
              icon: const Icon(Icons.delete_outline),
              tooltip: 'Delete history',
              onPressed: onDelete,
            ),
    );
  }
}

/// What deleting costs, under the list rather than only inside a dialog: it
/// is the thing a user has come here uncertain about, and reading it should
/// not require tapping a delete first.
class _Explanation extends StatelessWidget {
  const _Explanation();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 24, 16, 32),
      child: Text(
        'Sync history is what lets a run skip the files it already handled. '
        'Deleting it never touches your files: the next run reads and '
        'rehashes the whole folder and treats everything as new, as the '
        'first run did.',
        style: theme.textTheme.bodySmall?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }
}

/// The confirmation before deleting one archive. Says what is lost (the
/// shortcut), what is not (the files), and what it will cost next time.
class _DeleteDialog extends StatelessWidget {
  const _DeleteDialog({required this.row});

  final ArchiveRow row;

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text('Delete history for ${row.title}?'),
      content: Text(
        'This frees ${row.sizeLabel} and does not touch any of your files.\n\n'
        'The next run over this folder reads and rehashes all of it, and '
        'treats every file as new — the same work the first run did.',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const Key('archives-confirm-delete'),
          onPressed: () => Navigator.of(context).pop(true),
          child: const Text('Delete'),
        ),
      ],
    );
  }
}

/// The confirmation before deleting every archive — the same sentences, over
/// however many the list holds.
class _DeleteAllDialog extends StatelessWidget {
  const _DeleteAllDialog({required this.count});

  final int count;

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(
        count == 1 ? 'Delete all history?' : 'Delete all $count histories?',
      ),
      content: const Text(
        'This does not touch any of your files.\n\n'
        'Every run then reads and rehashes its whole folder once more and '
        'treats every file as new, as it did the first time.',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const Key('archives-confirm-delete-all'),
          onPressed: () => Navigator.of(context).pop(true),
          child: const Text('Delete all'),
        ),
      ],
    );
  }
}

/// The confirmation before deleting the ticked archives — the same sentences
/// as over all of them, over however many were picked.
class _DeleteSelectedDialog extends StatelessWidget {
  const _DeleteSelectedDialog({required this.count});

  final int count;

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(
        count == 1 ? 'Delete 1 history?' : 'Delete $count histories?',
      ),
      content: const Text(
        'This does not touch any of your files.\n\n'
        'Each run whose history goes reads and rehashes its whole folder '
        'once more and treats every file as new, as it did the first time.',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const Key('archives-confirm-delete-selected'),
          onPressed: () => Navigator.of(context).pop(true),
          child: const Text('Delete'),
        ),
      ],
    );
  }
}
