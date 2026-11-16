import 'package:flutter/gestures.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';

import '../../focus_ring.dart';
import '../../keyboard_first.dart';
import '../../path_text.dart';
import '../../pop_on_escape.dart';
import '../../readable_width.dart';
import '../../row_action.dart';
import '../../row_actions_menu.dart';
import 'filter_row_actions.dart';
import 'filters_controller.dart';
import 'filters_layout.dart';
import 'filters_listing_keys.dart';
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
/// **On a wide window the rules and the preview move into a side pane**
/// ([FiltersLayout]) and the listing takes the rest, so adding a rule shows
/// its effect on the rows and on the counts while the user carries on
/// browsing — stacked, the listing would sit under the fold of a window
/// that is mostly empty. The page reads its width once, here, and hands
/// the layout down.
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

  /// The listing keeps its state — the keyboard cursor, the focus, the
  /// scroll position — when a window resized across the breakpoint moves
  /// it from one layout's tree to the other's.
  final _listingKey = GlobalKey(debugLabel: 'filters-listing');

  @override
  void initState() {
    super.initState();
    _controller.open(widget.args);
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final layout = FiltersLayout.forWidth(constraints.maxWidth);
        return PopOnEscape(
          child: PopScope(
            // The result travels on the way out rather than from a Save
            // button: every edit is already live on this screen, so a
            // button that "applied" them would be asking the user to
            // confirm what they can already see.
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
                        // Selectable because the path is the one thing on
                        // the page a user may want to take elsewhere — a
                        // terminal, a file manager — and it is often too
                        // long to retype.
                        // Shortened from the middle to the bar's width;
                        // a selection still copies the whole path.
                        child: SelectionArea(
                          child: PathText(
                            _controller.state.rootPath,
                            key: const Key('filters-root-path'),
                            style: Theme.of(context).textTheme.bodySmall,
                            leafStyle: null,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              body: ListenableBuilder(
                listenable: _controller.state,
                builder: (context, _) => switch (layout) {
                  FiltersLayout.stacked => _stacked(context, layout),
                  FiltersLayout.sidePane => _sidePane(context, layout),
                },
              ),
            ),
          ),
        );
      },
    );
  }

  /// The phone's page: one column, the listing taking the height left.
  Widget _stacked(BuildContext context, FiltersLayout layout) {
    return Column(
      children: [
        ReadableColumn(
          width: ReadableWidth.list,
          child: _RulesSection(
            controller: _controller,
            layout: layout,
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
          child: _PathBar(controller: _controller, path: _crumbPath()),
        ),
        Expanded(child: _listing()),
      ],
    );
  }

  /// The wide page: the rules and the preview in a pane of their own, the
  /// path bar and the listing beside it.
  ///
  /// The pane scrolls on its own, so a long rule list never pushes the
  /// preview's counts — what a rule change is checked against — out of a
  /// window that has the height for them.
  Widget _sidePane(BuildContext context, FiltersLayout layout) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(
          key: const Key('filters-side-pane'),
          width: FiltersLayout.sidePaneWidth,
          child: ListView(
            children: [
              _RulesSection(
                controller: _controller,
                layout: layout,
                onAdd: () => _addRule(context),
              ),
              const Divider(height: 1),
              _PreviewSection(controller: _controller),
            ],
          ),
        ),
        const VerticalDivider(width: 1),
        Expanded(
          child: Column(
            children: [
              ReadableColumn(
                width: ReadableWidth.list,
                child: _PathBar(controller: _controller, path: _crumbPath()),
              ),
              Expanded(child: _listing()),
            ],
          ),
        ),
      ],
    );
  }

  /// The folder the breadcrumb names: the listed one, or the root while a
  /// listing is in flight or has failed.
  String _crumbPath() => switch (_controller.state.folder) {
    FiltersFolderListed(:final path) => path,
    FiltersFolderLoading() || FiltersFolderFailed() => '',
  };

  Widget _listing() => _Listing(
    key: _listingKey,
    controller: _controller,
    folder: _controller.state.folder,
  );

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
  const _RulesSection({
    required this.controller,
    required this.layout,
    required this.onAdd,
  });

  final FiltersController controller;

  /// Where the listing is, which the empty state points the user at.
  final FiltersLayout layout;
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
              switch (layout) {
                FiltersLayout.stacked =>
                  'No rules — everything in this folder syncs. Exclude '
                      'something by tapping it in the list below.',
                FiltersLayout.sidePane =>
                  'No rules — everything in this folder syncs. Exclude '
                      "something from its row's menu in the list.",
              },
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
            // Selectable on its own, as every error line is; the rules and
            // the listing beside it answer clicks (`CopyValueButton` states
            // the rule).
            Expanded(
              child: SelectionArea(
                child: Text(
                  message,
                  key: const Key('filters-preview-failed'),
                  style: TextStyle(color: theme.colorScheme.error),
                ),
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
/// back to it, which is the only pointer way up as well: an "up" button
/// and a breadcrumb are the same control drawn twice. (The keyboard's way
/// up is Backspace on the listing.)
///
/// **It stays scrolled to the folder being listed** — the last segment. A
/// path deeper than the row is wide is cut at the root end, which is the
/// end the user already knows.
///
/// **A vertical mouse wheel scrolls it sideways.** Most wheels turn one way
/// only, and a row that scrolled only on a horizontal delta would leave the
/// start of a deep path out of a mouse user's reach. Shift+wheel and a
/// trackpad's sideways swipe still reach the row's own scroll view first,
/// which takes them as it always did.
class _PathBar extends StatefulWidget {
  const _PathBar({required this.controller, required this.path});

  final FiltersController controller;

  /// The folder the segments spell out, root-relative; `''` is the root.
  final String path;

  @override
  State<_PathBar> createState() => _PathBarState();
}

class _PathBarState extends State<_PathBar> {
  final _scroll = ScrollController();

  @override
  void initState() {
    super.initState();
    _showCurrent();
  }

  @override
  void didUpdateWidget(_PathBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.path != widget.path) _showCurrent();
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  /// Scrolls to the last segment once the new segments are laid out.
  void _showCurrent() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scroll.hasClients) return;
      _scroll.jumpTo(_scroll.position.maxScrollExtent);
    });
  }

  /// A wheel turned up or down, with nothing sideways in it, moves the row
  /// left or right by as much. Registered with the resolver like a
  /// scroll view's own claim, so an event something deeper already took
  /// is not scrolled twice.
  void _onPointerSignal(PointerSignalEvent event) {
    if (event is! PointerScrollEvent || !_scroll.hasClients) return;
    final delta = event.scrollDelta;
    if (delta.dy == 0 || delta.dx != 0) return;
    final position = _scroll.position;
    final target = (position.pixels + delta.dy).clamp(
      position.minScrollExtent,
      position.maxScrollExtent,
    );
    if (target == position.pixels) return;
    GestureBinding.instance.pointerSignalResolver.register(
      event,
      (_) => position.pointerScroll(delta.dy),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final path = widget.path;
    final segments = path.isEmpty ? const <String>[] : path.split('/');
    return Listener(
      key: const Key('filters-path-bar'),
      onPointerSignal: _onPointerSignal,
      child: SizedBox(
        height: 40,
        child: ListView(
          controller: _scroll,
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 8),
          children: [
            TextButton(
              key: const Key('filters-crumb-root'),
              onPressed: () => widget.controller.openFolder(''),
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
                onPressed: () => widget.controller.openFolder(
                  segments.take(i + 1).join('/'),
                ),
                child: Text(segments[i]),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// The folder's contents: what is in the sync, what a rule keeps out, and
/// the way to change either.
///
/// **Browsable from the keyboard.** The listing is one focus stop with a
/// cursor on one of its rows: Up and Down move it, Home and End jump,
/// Enter opens a folder, Backspace or Alt+Up opens the one above
/// ([ListingCommand]). The keys are heard only while the listing holds the
/// focus itself — once Tab has put it on a row's menu button, Enter is
/// that button's, as everywhere else in the app — and a click on a row
/// moves the cursor there and hands the keys back. Esc is not here: it
/// leaves the page from anywhere on it ([PopOnEscape]).
///
/// **The Menu key and Shift+F10 open the cursor row's menu** on a desktop,
/// the one a right-click on the row opens ([RowActionsMenu]). The rows take
/// no focus of their own, so the listing hears the key and opens the row's
/// menu through a [RowMenuHandle] it gives the cursor's row alone.
///
/// **The ring shows only for a keyboard user:** while the listing holds
/// the focus and the app's focus highlight is in its keyboard mode. A tap
/// moves the cursor too and draws nothing, the way Material hides every
/// focus highlight after a touch.
///
/// **On a desktop the listing takes the focus on arrival** ([keyboardFirst]),
/// so the arrows work before anything is clicked. On a phone nothing is
/// focused, as before.
///
/// **Every row is the height of one prototype row.** A row is a one-line
/// name over a one-line status, so the rows are equal anyway; saying so
/// lets the list lay out a folder of thousands without building them, and
/// lets a key bring the cursor's row into view by arithmetic
/// ([revealOffset]) whether or not the row has been built.
class _Listing extends StatefulWidget {
  const _Listing({super.key, required this.controller, required this.folder});

  final FiltersController controller;

  /// What the view state says is listed — a parameter rather than read
  /// off [controller], so a new listing reaches [State.didUpdateWidget],
  /// where the cursor is settled on it.
  final FiltersFolder folder;

  @override
  State<_Listing> createState() => _ListingState();
}

class _ListingState extends State<_Listing> {
  final _focus = FocusNode(debugLabel: 'filters-listing');
  final _scroll = ScrollController();

  /// The cursor's row's menu, for the Menu key.
  final _cursorMenu = RowMenuHandle();

  /// The row the cursor is on, root-relative; `null` while nothing is
  /// listed or the folder is empty.
  String? _at;

  /// The folder last listed, so the next listing knows where the user came
  /// from ([cursorAfterListing]).
  String? _shownPath;

  /// The list's own padding at its last layout: with the scroll position,
  /// all [revealOffset] needs.
  EdgeInsets _padding = EdgeInsets.zero;

  /// A row with no rule and no path, for the list to measure every row's
  /// height by.
  static const _prototype = FilterEntryRow(
    name: 'M',
    path: '',
    isFolder: true,
    status: FilterEntrySyncs(),
    detail: 'M',
  );

  @override
  void initState() {
    super.initState();
    _focus.addListener(_redraw);
    FocusManager.instance.addHighlightModeListener(_onHighlightMode);
    _settle(widget.folder);
  }

  @override
  void didUpdateWidget(_Listing oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.folder, widget.folder)) _settle(widget.folder);
  }

  @override
  void dispose() {
    FocusManager.instance.removeHighlightModeListener(_onHighlightMode);
    _focus
      ..removeListener(_redraw)
      ..dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _redraw() => setState(() {});

  void _onHighlightMode(FocusHighlightMode _) => _redraw();

  bool get _ringShown =>
      _focus.hasPrimaryFocus &&
      FocusManager.instance.highlightMode == FocusHighlightMode.traditional;

  /// Puts the cursor where [folder] leaves it, and — when it is a different
  /// folder from the last — brings that row into view once it is laid out.
  void _settle(FiltersFolder folder) {
    if (folder is! FiltersFolderListed) return;
    final moved = folder.path != _shownPath;
    _at = cursorAfterListing(folder, cameFrom: _shownPath, at: _at);
    _shownPath = folder.path;
    if (moved) _revealAfterLayout();
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    final repeat = event is KeyRepeatEvent;
    if (event is! KeyDownEvent && !repeat) return KeyEventResult.ignored;
    final folder = widget.folder;
    if (!node.hasPrimaryFocus || folder is! FiltersFolderListed) {
      return KeyEventResult.ignored;
    }
    final keyboard = HardwareKeyboard.instance;
    if (_at != null &&
        rowMenuActivators.any((keys) => keys.accepts(event, keyboard))) {
      _openCursorMenu();
      return KeyEventResult.handled;
    }
    final command = ListingCommand.forKey(
      event.logicalKey,
      folder: folder,
      at: _at,
      alt: keyboard.isAltPressed,
      modified:
          keyboard.isControlPressed ||
          keyboard.isMetaPressed ||
          keyboard.isShiftPressed,
    );
    switch (command) {
      case null:
        return KeyEventResult.ignored;
      case MoveListingCursor(:final path):
        setState(() => _at = path);
        _revealAfterLayout();
      // A held arrow walks the list; a held Enter or Backspace opens once.
      case OpenListingFolder() when repeat:
        break;
      case OpenListingFolder(:final path):
        widget.controller.openFolder(path);
    }
    return KeyEventResult.handled;
  }

  /// Opens the cursor row's menu. A row the lazy list has not built — the
  /// cursor scrolled out of view by the wheel — is brought into view first,
  /// and its menu opened in the frame after the one that builds it.
  void _openCursorMenu() {
    if (_cursorMenu.open()) return;
    _revealAfterLayout();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      // The reveal jumps in this frame's callbacks; the row is built in the
      // next frame.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _cursorMenu.open();
      });
      WidgetsBinding.instance.ensureVisualUpdate();
    });
  }

  /// A pointer went down on the row at [path]: the cursor follows it, and
  /// the listing takes the keys, so the keyboard carries on from where the
  /// mouse last was.
  void _press(String path) {
    setState(() => _at = path);
    _focus.requestFocus();
  }

  /// Scrolls the cursor's row just wholly into view, after the frame that
  /// lays out whatever changed — a new folder's rows, or none at all for a
  /// key that only moved the cursor.
  void _revealAfterLayout() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final folder = widget.folder;
      if (!mounted || !_scroll.hasClients) return;
      if (folder is! FiltersFolderListed) return;
      final index = folder.entries.indexWhere((entry) => entry.path == _at);
      final position = _scroll.position;
      if (index < 0 || position.maxScrollExtent <= position.minScrollExtent) {
        return;
      }
      final to = revealOffset(
        index: index,
        count: folder.entries.length,
        content: position.maxScrollExtent + position.viewportDimension,
        leading: _padding.top,
        trailing: _padding.bottom,
        viewport: position.viewportDimension,
        pixels: position.pixels,
      );
      if (to == null) return;
      position.jumpTo(
        to.clamp(position.minScrollExtent, position.maxScrollExtent),
      );
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  @override
  Widget build(BuildContext context) {
    return Focus(
      focusNode: _focus,
      autofocus: keyboardFirst(context),
      includeSemantics: false,
      onKeyEvent: _onKey,
      child: switch (widget.folder) {
        FiltersFolderLoading() => const Center(
          child: CircularProgressIndicator(
            semanticsLabel: 'Opening the folder',
          ),
        ),
        FiltersFolderFailed(:final message) => ReadableColumn(
          width: ReadableWidth.list,
          child: Padding(
            padding: const EdgeInsets.all(24),
            // Selectable on its own, as every error line is: a folder that
            // failed to list has no rows here to take the click from it.
            child: SelectionArea(
              child: Text(
                message,
                key: const Key('filters-folder-failed'),
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
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
          builder: (context, padding) {
            _padding = padding;
            final ringShown = _ringShown;
            return ListView.builder(
              controller: _scroll,
              padding: padding,
              itemCount: entries.length,
              prototypeItem: _EntryTile(
                controller: widget.controller,
                entry: _prototype,
                ringed: false,
                menu: null,
                onPress: () {},
              ),
              itemBuilder: (context, i) {
                final entry = entries[i];
                return _EntryTile(
                  controller: widget.controller,
                  entry: entry,
                  ringed: ringShown && entry.path == _at,
                  menu: entry.path == _at ? _cursorMenu : null,
                  onPress: () => _press(entry.path),
                );
              },
            );
          },
        ),
      },
    );
  }
}

/// One row of the listing: what it is, whether it syncs, and — behind the
/// trailing button — what can be done about it.
///
/// The verdict is drawn as well as written: an excluded row is dimmed and
/// says which rule did it, so a folder that is out of the sync is visibly
/// out while scrolling, rather than something to be read for.
///
/// [ringed] draws the keyboard cursor's [FocusRing] inside the row's own
/// bounds, so the row does not move for it — nor change height, which
/// every row shares with the listing's prototype.
class _EntryTile extends StatelessWidget {
  const _EntryTile({
    required this.controller,
    required this.entry,
    required this.ringed,
    required this.menu,
    required this.onPress,
  });

  final FiltersController controller;
  final FilterEntryRow entry;
  final bool ringed;

  /// The listing's way to open this row's menu from the keyboard, on the
  /// cursor's row only.
  final RowMenuHandle? menu;

  /// A pointer went down anywhere on the row — its menu button included.
  final VoidCallback onPress;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final excluded = entry.status is FilterEntryExcluded;
    final quiet = theme.colorScheme.onSurfaceVariant;
    final actions = filterRowActions(
      entry.actions,
      run: controller.runEntryAction,
    );
    // A right-click is a pointer down too: the cursor moves to the row
    // before its menu opens, so the keys carry on from there.
    return RowActionsMenu(
      actions: actions,
      focusNode: null,
      handle: menu,
      child: Listener(
        behavior: HitTestBehavior.translucent,
        onPointerDown: (_) => onPress(),
        child: ListTile(
          key: Key('filters-entry-${entry.path}'),
          // The tile's own shape and colour, not a box around it: the tile
          // draws them on the Material beneath with its ink, which a
          // filled box in between would hide.
          shape: ringed ? FocusRing.shape(theme.colorScheme) : null,
          tileColor: ringed ? FocusRing.fill(theme.colorScheme) : null,
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
          onTap: entry.isFolder
              ? () => controller.openFolder(entry.path)
              : null,
          trailing: _EntryMenu(
            controller: controller,
            entry: entry,
            actions: actions,
          ),
        ),
      ),
    );
  }
}

/// The actions on a row ([FilterEntryRow.actions]): exclude it by name,
/// exclude this one only, or — when a rule is already keeping it out —
/// drop that rule.
///
/// A menu rather than a swipe or a checkbox: "exclude everywhere" and
/// "exclude this one" are genuinely different rules, and a control with
/// one gesture would have to guess which the user meant. A row that a rule
/// already covers offers the way back as a button of its own, so an
/// excluded folder is not a dead end the user has to go find the rule for.
///
/// The ⋮ menu renders [actions], the list the row's context menu renders.
class _EntryMenu extends StatelessWidget {
  const _EntryMenu({
    required this.controller,
    required this.entry,
    required this.actions,
  });

  final FiltersController controller;
  final FilterEntryRow entry;
  final List<RowAction> actions;

  @override
  Widget build(BuildContext context) {
    return switch (entry.actions) {
      [] => const SizedBox.shrink(),
      [final IncludeAgain include] => TextButton(
        key: Key('filters-include-${entry.path}'),
        onPressed: () => controller.runEntryAction(include),
        child: Text(include.label),
      ),
      _ => RowActionsButton(
        key: Key('filters-menu-${entry.path}'),
        actions: actions,
        tooltip: 'Exclude ${entry.name}',
      ),
    };
  }
}

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
