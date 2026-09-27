import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../archive_row.dart';
import '../../destructive_confirm_dialog.dart';
import '../../keyboard_first.dart';
import '../../path_text.dart';
import '../../readable_width.dart';
import '../../refresh_action.dart';
import '../../row_action.dart';
import '../../row_actions_menu.dart';
import 'archive_row_actions.dart';
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
/// **Rows can be ticked, and the ticked ones deleted together.** The app
/// bar then says how many are picked and carries the delete. It exists for
/// the middle case the other two buttons miss: three dead histories out of
/// a dozen, where deleting each in turn is four taps apiece and "delete
/// all" costs the nine that are still earning their keep.
///
/// **How ticking starts is the platform's own.** On a phone it is a long
/// press, and once selecting a tap. On a desktop ([keyboardFirst]) a long
/// press is not a thing a mouse does, so every row carries a checkbox,
/// always drawn rather than on hover — a keyboard user never hovers, and a
/// box that appears under the pointer shifts the row's text as the mouse
/// crosses the list — and the bar carries "Select all". There a plain
/// click focuses a row (or ticks it once selecting), Ctrl/Cmd-click ticks
/// one, Shift-click ranges from the last row clicked, and the keyboard has
/// the rest: Up/Down move between rows, Shift+Up/Down extend, Space ticks,
/// Ctrl/Cmd+A ticks all, Delete deletes what is ticked (or the focused row)
/// behind the same confirmation, and Esc stops selecting. The selection is
/// the controller's ([ArchivesViewState.selection]); the page only reads
/// the modifier keys and says which operation a click was. A right-click on
/// a row, or the Menu key on a focused one, opens the row's menu
/// ([archiveRowActions]): on the selection when the row is ticked, on the
/// row alone otherwise, the ticks left as they are.
///
/// **Esc stops selecting before it leaves.** In the shell's pane Esc pops
/// the page; while rows are ticked it is heard here first and only clears
/// them — the handler nearest the focus wins — and with nothing ticked it
/// passes on to the shell untouched.
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

  /// Each row's focus, by log path — what Up/Down move and Space ticks. A
  /// node outlives a deleted row until this page goes, for the reason the
  /// Devices list keeps its own that way: disposing it in the frame its row
  /// is still unmounting in would pull it from under the row.
  final _rowFocus = <String, FocusNode>{};

  FocusNode _focusOf(String logPath) => _rowFocus.putIfAbsent(
    logPath,
    () => FocusNode(debugLabel: 'archive row $logPath'),
  );

  /// The row holding the focus, itself or a button inside it, or `null`.
  String? get _focusedRow {
    for (final MapEntry(key: logPath, value: node) in _rowFocus.entries) {
      if (node.hasFocus) return logPath;
    }
    return null;
  }

  @override
  void initState() {
    super.initState();
    _controller.refresh();
  }

  @override
  void dispose() {
    for (final node in _rowFocus.values) {
      node.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // The whole scaffold rebuilds on the view state, not just the body: the
    // app-bar action exists only over a list with rows, so it is as much a
    // reader of the listing as the body is.
    //
    // The keys are heard above RefreshShortcuts' autofocused node, so Ctrl+A
    // and Esc work the moment the page is shown, before any row is clicked.
    return Focus(
      canRequestFocus: false,
      skipTraversal: true,
      onKeyEvent: _onKey,
      child: RefreshShortcuts(
        onRefresh: _controller.refresh,
        child: ListenableBuilder(
          listenable: _controller.state,
          builder: (context, _) => _scaffold(context),
        ),
      ),
    );
  }

  KeyEventResult _onKey(FocusNode _, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final keyboard = HardwareKeyboard.instance;
    final command = keyboard.isControlPressed || keyboard.isMetaPressed;
    final shift = keyboard.isShiftPressed;
    final handled = switch (event.logicalKey) {
      LogicalKeyboardKey.escape when !command && !shift => _stopSelecting(),
      LogicalKeyboardKey.keyA when command && !shift => _selectAll(),
      LogicalKeyboardKey.delete when !command && !shift => _deleteByKey(),
      LogicalKeyboardKey.arrowUp when !command => _step(-1, extend: shift),
      LogicalKeyboardKey.arrowDown when !command => _step(1, extend: shift),
      LogicalKeyboardKey.space when !command && !shift => _toggleFocused(),
      _ => false,
    };
    return handled ? KeyEventResult.handled : KeyEventResult.ignored;
  }

  /// Esc: clears the ticks, or — with none — leaves the key to the shell.
  bool _stopSelecting() {
    if (!_controller.state.isSelecting) return false;
    _controller.clearSelection();
    return true;
  }

  bool _selectAll() {
    if (_controller.state.listing case ArchivesReady(:final rows)
        when rows.isNotEmpty) {
      _controller.selectAll();
      return true;
    }
    return false;
  }

  /// Delete: the ticked rows when there are any, else the focused row —
  /// each behind the confirmation its button asks.
  bool _deleteByKey() {
    if (_controller.state.isSelecting) {
      _confirmDeleteSelected(context, _controller.state.selected.length);
      return true;
    }
    final focused = _focusedRow;
    if (_controller.state.listing case ArchivesReady(:final rows)) {
      for (final row in rows) {
        if (row.logPath == focused) {
          _confirmDelete(context, row);
          return true;
        }
      }
    }
    return false;
  }

  /// Up or Down: focuses the next row, and with Shift ranges the selection
  /// to it — from the anchor, or from the row being left when nothing has
  /// been clicked yet. At either end the key is spent and nothing moves.
  bool _step(int step, {required bool extend}) {
    final from = _focusedRow;
    final next = _controller.rowBeside(from, step);
    if (next == null) return from != null;
    if (extend) _controller.selectRange(from: from, to: next);
    final node = _focusOf(next)..requestFocus();
    // Scrolled to once the row is laid out: its bottom edge into view
    // moving down, its top moving up, and nothing when it is in view.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final row = node.context;
      if (row == null || !row.mounted) return;
      Scrollable.ensureVisible(
        row,
        alignmentPolicy: step < 0
            ? ScrollPositionAlignmentPolicy.keepVisibleAtStart
            : ScrollPositionAlignmentPolicy.keepVisibleAtEnd,
      );
    });
    return true;
  }

  /// Space on a row: ticks or unticks it. Only on the row itself — Space
  /// on the delete button inside it is that button's.
  bool _toggleFocused() {
    for (final MapEntry(key: logPath, value: node) in _rowFocus.entries) {
      if (node.hasPrimaryFocus) {
        _controller.toggleSelection(logPath);
        return true;
      }
    }
    return false;
  }

  /// A click on [logPath]'s row, or on its checkbox when [onCheckbox]:
  /// Shift ranges, Ctrl/Cmd ticks, and a plain click ticks once selecting
  /// or on the box. A plain click on a row while nothing is ticked only
  /// focuses it, so the keys have a row to start from.
  void _click(String logPath, {required bool onCheckbox}) {
    final keyboard = HardwareKeyboard.instance;
    final from = _focusedRow;
    _focusOf(logPath).requestFocus();
    if (keyboard.isShiftPressed) {
      _controller.selectRange(from: from, to: logPath);
    } else if (onCheckbox ||
        keyboard.isControlPressed ||
        keyboard.isMetaPressed ||
        _controller.state.isSelecting) {
      _controller.toggleSelection(logPath);
    }
  }

  Widget _scaffold(BuildContext context) {
    final checkboxes = keyboardFirst(context);
    return Scaffold(
      appBar: _controller.state.isSelecting
          ? _selectionAppBar(context, selectAll: checkboxes)
          : _titleAppBar(context, selectAll: checkboxes),
      body: _ArchivesBody(
        controller: _controller,
        checkboxes: checkboxes,
        focusOf: _focusOf,
        onClick: _click,
        onDelete: (row) => _confirmDelete(context, row),
        onDeleteSelected: () =>
            _confirmDeleteSelected(context, _controller.state.selected.length),
      ),
    );
  }

  /// The desktop's explicit way into selecting: tick every row, with the
  /// shortcut named in its tooltip. An action that entered an empty
  /// selection mode instead would need a mode flag beside the set, and
  /// with a checkbox on every row there is nothing such a mode would add.
  Widget _selectAllButton(BuildContext context) {
    final mac = Theme.of(context).platform == TargetPlatform.macOS;
    return IconButton(
      key: const Key('archives-select-all'),
      icon: const Icon(Icons.select_all),
      tooltip: 'Select all (${mac ? 'Cmd' : 'Ctrl'}+A)',
      onPressed: _controller.selectAll,
    );
  }

  AppBar _titleAppBar(BuildContext context, {required bool selectAll}) {
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
            when rows.isNotEmpty) ...[
          if (selectAll) _selectAllButton(context),
          IconButton(
            key: const Key('archives-delete-all'),
            icon: const Icon(Icons.delete_sweep_outlined),
            tooltip: 'Delete all history',
            onPressed: () => _confirmDeleteAll(context, rows.length),
          ),
        ],
      ],
    );
  }

  /// The bar while rows are ticked: what is ticked, a way out that deletes
  /// nothing, and the delete. "Delete all" is gone from it on purpose —
  /// having picked three of a dozen, the button next to the count should
  /// not be the one that takes the other nine.
  AppBar _selectionAppBar(BuildContext context, {required bool selectAll}) {
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
        if (selectAll) _selectAllButton(context),
        IconButton(
          key: const Key('archives-delete-selected'),
          icon: const Icon(Icons.delete_outline),
          tooltip: 'Delete selected history',
          onPressed: () => _confirmDeleteSelected(context, count),
        ),
      ],
    );
  }

  Future<void> _confirmDelete(BuildContext context, ArchiveRow row) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => _DeleteDialog(row: row),
    );
    if (confirmed ?? false) await _controller.delete(row.logPath);
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
  const _ArchivesBody({
    required this.controller,
    required this.checkboxes,
    required this.focusOf,
    required this.onClick,
    required this.onDelete,
    required this.onDeleteSelected,
  });

  final ArchivesController controller;

  /// Whether rows carry a checkbox — the desktop's way in to selecting.
  final bool checkboxes;
  final FocusNode Function(String logPath) focusOf;
  final void Function(String logPath, {required bool onCheckbox}) onClick;
  final void Function(ArchiveRow row) onDelete;
  final VoidCallback onDeleteSelected;

  @override
  Widget build(BuildContext context) {
    final error = controller.state.error;
    final state = controller.state;
    return RefreshIndicator(
      onRefresh: controller.refresh,
      child: ReadableScrollPadding(
        width: ReadableWidth.list,
        padding: null,
        builder: (context, padding) => ListView(
          padding: padding,
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
                    checkbox: checkboxes,
                    focusNode: focusOf(row.logPath),
                    isSelecting: state.isSelecting,
                    isSelected: state.isSelected(row.logPath),
                    onClick: () => onClick(row.logPath, onCheckbox: false),
                    onCheck: () => onClick(row.logPath, onCheckbox: true),
                    onLongPress: () => controller.toggleSelection(row.logPath),
                    onDelete: () => onDelete(row),
                    actions: archiveRowActions(
                      row,
                      isSelecting: state.isSelecting,
                      isSelected: state.isSelected(row.logPath),
                      selectedCount: state.selected.length,
                      onToggle: () => controller.toggleSelection(row.logPath),
                      onDelete: () => onDelete(row),
                      onDeleteSelected: onDeleteSelected,
                    ),
                  ),
                const _Explanation(),
              ],
            },
          ],
        ),
      ),
    );
  }
}

/// An error line above the list — a delete refused by a run in progress, or
/// a state directory that could not be read — in the theme's error colour.
class _NoticeTile extends StatelessWidget {
  const _NoticeTile(this.message);

  final String message;

  @override
  Widget build(BuildContext context) {
    // Selectable on its own, the rows around it left out: they answer
    // clicks (`CopyValueButton` states the rule), and this line is the one
    // on the page worth pasting into a bug report.
    return SelectionArea(
      child: ListTile(
        key: const Key('archives-notice'),
        leading: Icon(
          Icons.error_outline,
          color: Theme.of(context).colorScheme.error,
        ),
        title: Text(message),
      ),
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
    required this.checkbox,
    required this.focusNode,
    required this.isSelecting,
    required this.isSelected,
    required this.onClick,
    required this.onCheck,
    required this.onLongPress,
    required this.onDelete,
    required this.actions,
  });

  final ArchiveRow row;

  /// Whether the row leads with a checkbox (the desktop) rather than with a
  /// tick mark drawn only while selecting (a phone). The desktop's row is
  /// clickable, and so focusable, even when nothing is ticked, so the
  /// keyboard can walk the list.
  final bool checkbox;
  final FocusNode focusNode;

  /// Whether any row on the page is ticked. While that holds, a tap ticks
  /// this row rather than doing nothing, and the per-row delete gives way to
  /// the one in the bar — two deletes on screen, one over this row and one
  /// over the selection, is a way to delete the wrong thing.
  final bool isSelecting;
  final bool isSelected;
  final VoidCallback onClick;
  final VoidCallback onCheck;
  final VoidCallback onLongPress;
  final VoidCallback onDelete;

  /// The row's context menu on a desktop ([archiveRowActions]): on the
  /// selection when this row is in it, on this row otherwise.
  final List<RowAction> actions;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final note = row.note;
    final peerLine = row.peerLine;
    return RowActionsMenu(
      actions: actions,
      focusNode: focusNode,
      handle: null,
      child: ListTile(
        key: Key('archive-row-${row.logPath}'),
        focusNode: focusNode,
        selected: isSelected,
        // Long press starts selecting, the platform's own gesture for it; once
        // selecting, a plain tap is enough.
        onLongPress: onLongPress,
        onTap: checkbox || isSelecting ? onClick : null,
        leading: checkbox
            // Out of the focus order: the row is the keyboard's stop and Space
            // on it ticks, so a second stop per row would only double the Tabs
            // down the list.
            ? ExcludeFocus(
                child: Checkbox(
                  key: Key('archive-check-${row.logPath}'),
                  value: isSelected,
                  onChanged: (_) => onCheck(),
                ),
              )
            : isSelecting
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
            // Hover-only tooltip (see [PathText]): a long-press here is the
            // row's own, and starts selecting.
            switch (row.rootPath) {
              final path? => PathText(path, style: null, leafStyle: null),
              null => const Text(ArchiveRow.unknownLocation),
            },
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
    return DestructiveConfirmDialog(
      title: 'Delete history for ${row.title}?',
      message:
          'This frees ${row.sizeLabel} and does not touch any of your files.'
          '\n\n'
          'The next run over this folder reads and rehashes all of it, and '
          'treats every file as new — the same work the first run did.',
      cancelLabel: 'Cancel',
      confirmLabel: 'Delete',
      cancelKey: const Key('archives-cancel-delete'),
      confirmKey: const Key('archives-confirm-delete'),
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
    return DestructiveConfirmDialog(
      title: count == 1
          ? 'Delete all history?'
          : 'Delete all $count histories?',
      message:
          'This does not touch any of your files.\n\n'
          'Every run then reads and rehashes its whole folder once more and '
          'treats every file as new, as it did the first time.',
      cancelLabel: 'Cancel',
      confirmLabel: 'Delete all',
      cancelKey: const Key('archives-cancel-delete-all'),
      confirmKey: const Key('archives-confirm-delete-all'),
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
    return DestructiveConfirmDialog(
      title: count == 1 ? 'Delete 1 history?' : 'Delete $count histories?',
      message:
          'This does not touch any of your files.\n\n'
          'Each run whose history goes reads and rehashes its whole folder '
          'once more and treats every file as new, as it did the first time.',
      cancelLabel: 'Cancel',
      confirmLabel: 'Delete',
      cancelKey: const Key('archives-cancel-delete-selected'),
      confirmKey: const Key('archives-confirm-delete-selected'),
    );
  }
}
