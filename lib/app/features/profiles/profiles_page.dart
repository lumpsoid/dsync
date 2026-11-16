import 'package:material_ui/material_ui.dart';

import '../../core_link/models/last_run.dart';
import '../../destructive_confirm_dialog.dart';
import '../../path_text.dart';
import '../../profile_breakage.dart';
import '../../profile_row.dart';
import '../../readable_width.dart';
import '../../refresh_action.dart';
import '../../row_actions_menu.dart';
import '../../unsaved_run_row.dart';
import 'profile_row_actions.dart';
import 'profiles_chrome.dart';
import 'profiles_controller.dart';
import 'profiles_scope.dart';

/// The home page: the saved runs (the head's home list). Widgets only, per
/// the page role in `app_scope.dart`: every row is a [ProfileRow] of
/// already-rendered values — including [ProfileRow.breakage], which is the
/// whole of the brokenness decision — and the only branches here are over
/// that sealed case, picking which remedy button to draw.
///
/// Rows come from `AppState.profiles` through the controller's
/// `AppController`; this page holds no copy of them. It loads on mounting —
/// the store read that makes the list survive an app restart — rebuilds on
/// either notifier (the application state for the rows, the view state for
/// this page's own error line), and refreshes on pull, on the app-bar
/// [RefreshButton] or on F5 ([RefreshShortcuts]).
///
/// A broken profile renders as itself, not gone: not a tap target, with its
/// [ProfileBreakage] message and that breakage's remedy where the tap
/// summary would be. Revoking the device or losing the folder must be
/// visible from the home list, because the row is the only place the run
/// the user configured still exists — and it must be fixable there, because
/// the alternative is deleting the run and configuring it again.
///
/// On a desktop a right-click on a row, or the Menu key on a focused one,
/// opens its buttons as a menu with its paths to copy
/// ([profileRowActions]), and Delete asks to delete the focused row.
///
/// [onOpenProfile] is the seam to Run setup, fired with the tapped row's
/// profile id — an id, not a row, per the handoff rule.
/// [onOpenDevices] is the seam to Devices, from the app bar, from the empty
/// state, from the "New run" button and from the remedy on a row whose
/// device was revoked — Pair is reached through Devices, and this page has
/// no `Navigator` to reach it any other way: pairing and revoking still need a
/// device view, and every run — the first and every one after it — is born
/// there. The app-bar action keeps its own meaning, pairing; the button is
/// about running, and stays on screen once the list has rows. Both are the
/// entrypoint's to wire to routes, so this page needs no `Navigator` of its
/// own.
///
/// [chrome] says whether those app-bar actions and the button are drawn
/// here at all: on a wide window the app shell's rail carries them, and the
/// page keeps only what acts on the list itself.
class ProfilesPage extends StatefulWidget {
  const ProfilesPage({
    super.key,
    required this.onOpenProfile,
    required this.onOpenDevices,
    required this.chrome,
  });

  /// Opens Run setup pre-filled from the tapped profile, by id — the id is
  /// the whole handoff; the destination loads what it needs.
  final void Function(String profileName) onOpenProfile;

  /// Opens the Devices page.
  final VoidCallback onOpenDevices;

  /// Whether this page draws its own way to the other destinations — the
  /// app-bar actions and the "New run" button — or the shell draws them.
  final ProfilesChrome chrome;

  @override
  State<ProfilesPage> createState() => _ProfilesPageState();
}

class _ProfilesPageState extends State<ProfilesPage> {
  final ProfilesController _controller = profilesScope.controller;

  @override
  void initState() {
    super.initState();
    _controller.refresh();
  }

  @override
  Widget build(BuildContext context) {
    final chrome = widget.chrome;
    return RefreshShortcuts(
      onRefresh: _controller.refresh,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('dsync'),
          actions: [
            RefreshButton(
              key: const Key('profiles-refresh'),
              onRefresh: _controller.refresh,
            ),
            if (chrome is ProfilesOwnChrome) ...[
              IconButton(
                key: const Key('profiles-open-serve'),
                icon: const Icon(Icons.wifi_tethering),
                tooltip: 'Answer paired devices',
                onPressed: chrome.onOpenServe,
              ),
              IconButton(
                key: const Key('profiles-open-archives'),
                icon: const Icon(Icons.sd_storage_outlined),
                tooltip: 'Sync history',
                onPressed: chrome.onOpenArchives,
              ),
              IconButton(
                key: const Key('profiles-open-settings'),
                icon: const Icon(Icons.settings_outlined),
                tooltip: 'Settings',
                onPressed: chrome.onOpenSettings,
              ),
              TextButton(
                key: const Key('profiles-open-devices'),
                onPressed: widget.onOpenDevices,
                child: const Text('Devices'),
              ),
            ],
          ],
        ),
        body: ListenableBuilder(
          listenable: Listenable.merge([
            _controller.app.state,
            _controller.state,
          ]),
          builder: (context, _) => _ProfilesBody(
            controller: _controller,
            onOpenProfile: widget.onOpenProfile,
            onOpenDevices: widget.onOpenDevices,
          ),
        ),
        floatingActionButton: switch (chrome) {
          ProfilesOwnChrome() => FloatingActionButton.extended(
            key: const Key('profiles-new-run'),
            onPressed: widget.onOpenDevices,
            icon: const Icon(Icons.sync),
            label: const Text('New run'),
          ),
          ProfilesShellChrome() => null,
        },
      ),
    );
  }
}

class _ProfilesBody extends StatelessWidget {
  const _ProfilesBody({
    required this.controller,
    required this.onOpenProfile,
    required this.onOpenDevices,
  });

  final ProfilesController controller;
  final void Function(String profileName) onOpenProfile;
  final VoidCallback onOpenDevices;

  @override
  Widget build(BuildContext context) {
    final profiles = controller.app.state.profiles;
    final unsavedRuns = controller.app.state.unsavedRuns;
    final error = controller.state.error;
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
            for (final run in unsavedRuns) _UnsavedRunTile(run),
            if (profiles.isEmpty)
              _EmptyState(onOpenDevices: onOpenDevices)
            else
              for (final row in profiles)
                _ProfileTile(
                  row: row,
                  onTap: row.breakage == null
                      ? () => onOpenProfile(row.name)
                      : null,
                  onRunAgain: () => onOpenProfile(row.name),
                  onPickFolder: (entryIndex) =>
                      controller.repickLocalFolder(row.name, entryIndex),
                  onPairAgain: onOpenDevices,
                  onDelete: () => _confirmDelete(context, row),
                ),
          ],
        ),
      ),
    );
  }

  Future<void> _confirmDelete(BuildContext context, ProfileRow row) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => _DeleteDialog(row: row),
    );
    if (confirmed ?? false) await controller.delete(row.name);
  }
}

/// An error line above the list — a corrupt store or a stale delete — in
/// the theme's error colour.
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
        leading: Icon(
          Icons.error_outline,
          color: Theme.of(context).colorScheme.error,
        ),
        title: Text(message),
      ),
    );
  }
}

/// A run no saved profile claims that did not finish (task 75af93): its
/// two sides and what to do, in the error colour a profile row's own
/// warning uses. Nothing to tap — the run it names is started again from
/// Devices, as any unsaved run is.
class _UnsavedRunTile extends StatelessWidget {
  const _UnsavedRunTile(this.run);

  final UnsavedRunRow run;

  @override
  Widget build(BuildContext context) {
    final error = Theme.of(context).colorScheme.error;
    return SelectionArea(
      child: ListTile(
        key: Key('profiles-unsaved-run-${run.entryId}'),
        leading: Icon(Icons.warning_amber_outlined, color: error),
        title: Text(run.title),
        subtitle: Text(run.warning, style: TextStyle(color: error)),
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.onOpenDevices});

  final VoidCallback onOpenDevices;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(32),
      child: Column(
        children: [
          const Text('No saved sync profiles yet.'),
          const SizedBox(height: 16),
          FilledButton(
            onPressed: onOpenDevices,
            child: const Text('Sync with a device'),
          ),
        ],
      ),
    );
  }
}

class _ProfileTile extends StatelessWidget {
  const _ProfileTile({
    required this.row,
    required this.onTap,
    required this.onRunAgain,
    required this.onPickFolder,
    required this.onPairAgain,
    required this.onDelete,
  });

  final ProfileRow row;

  /// `null` on a broken profile: running it is what is broken, so the row
  /// is not a tap target until its remedy has been taken.
  final VoidCallback? onTap;

  /// The offer made to a profile whose last run did not finish (task
  /// 99f404): the same hop a tap makes, named for what it is for.
  final VoidCallback onRunAgain;

  /// Re-picks the local folder of the entry at the given index — the remedy
  /// for [ProfileLocalRootUnusable], aimed at its `entryIndex`.
  final void Function(int entryIndex) onPickFolder;

  /// Opens Devices, where the revoked peer can be paired with again — the
  /// remedy for [ProfileDeviceUnpaired].
  final VoidCallback onPairAgain;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final breakage = row.breakage;
    final shown = profileEntriesShown(row.entries);
    return RowActionsMenu(
      actions: profileRowActions(
        row,
        onRunAgain: onRunAgain,
        onPickFolder: onPickFolder,
        onPairAgain: onPairAgain,
        onDelete: onDelete,
      ),
      // The card's ink well takes the focus by itself; a right-click leaves
      // it where it was.
      focusNode: null,
      handle: null,
      child: Card(
        margin: const EdgeInsets.fromLTRB(12, 4, 12, 4),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(12),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 4, 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        row.name,
                        style: theme.textTheme.titleMedium,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.delete_outline),
                      tooltip: 'Delete profile',
                      onPressed: onDelete,
                    ),
                  ],
                ),
                // The pair, one side per block, headed the way Run setup
                // heads the same two fields ("On this device" / "On
                // <device>"): the two screens describe one run, and a row
                // that named the sides differently would read as a
                // different thing. It also puts the device where it belongs
                // — on the side that *is* the device — instead of on a line
                // of its own above a pair of anonymous paths. A revoked
                // device has no name on this host any more, only an id, and
                // the heading says so rather than leaving a blank where a
                // name was.
                //
                // Only the first two entries are drawn in full — a row is a
                // summary, not the editor — with the rest folded into a count.
                // A single-entry profile (still the common case) reads exactly
                // as it always has: no numbering, one pair of blocks.
                for (final (index, entry) in shown.indexed) ...[
                  if (index > 0) const SizedBox(height: 8),
                  _PairSide(label: 'On this device', path: entry.localRootPath),
                  const SizedBox(height: 8),
                  _PairSide(
                    label: 'On ${profilePeerLabel(row)}',
                    path: entry.remoteRootPath,
                  ),
                ],
                if (row.entries.length > 2) ...[
                  const SizedBox(height: 4),
                  Text(
                    'and ${row.entries.length - 2} more',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
                if (_lastRunWarning(row.lastRun) case final warning?) ...[
                  const SizedBox(height: 8),
                  Text(
                    warning,
                    style: TextStyle(color: theme.colorScheme.error),
                  ),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: TextButton(
                      key: Key('profile-run-again-${row.name}'),
                      onPressed: onRunAgain,
                      child: const Text('Run again'),
                    ),
                  ),
                ],
                if (breakage != null) ...[
                  const SizedBox(height: 8),
                  Text(
                    breakage.message,
                    style: TextStyle(color: theme.colorScheme.error),
                  ),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: switch (breakage) {
                      ProfileLocalRootUnusable(:final entryIndex) => TextButton(
                        key: Key('profile-pick-folder-${row.name}'),
                        onPressed: () => onPickFolder(entryIndex),
                        child: const Text('Choose folder'),
                      ),
                      ProfileDeviceUnpaired() => TextButton(
                        key: Key('profile-pair-again-${row.name}'),
                        onPressed: onPairAgain,
                        child: const Text('Pair again'),
                      ),
                    },
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// One side of the pair: where it is, and the folder it is.
///
/// The path is drawn in two weights — the parent quiet, the leaf in the
/// body colour and bolder ([PathText.leafStyle]). Every folder on a device
/// shares a long prefix, so printed at one weight the shared part is what
/// the eye lands on and the leaf, the only part that tells two saved runs
/// apart, is what it has to hunt for. Two weights put the distinguishing
/// part first in reading order without moving it in the path.
///
/// Shortened to the row's width by [PathText], the full path on hover: a
/// row is a click target in a listing outside any `SelectionArea`, so the
/// tooltip is how the whole path is read here.
class _PairSide extends StatelessWidget {
  const _PairSide({required this.label, required this.path});

  final String label;
  final String path;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: theme.textTheme.labelMedium?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
          overflow: TextOverflow.ellipsis,
        ),
        PathText(
          path,
          style: theme.textTheme.bodyMedium?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
          leafStyle: TextStyle(
            fontWeight: FontWeight.w600,
            color: theme.textTheme.bodyMedium?.color,
          ),
        ),
      ],
    );
  }
}

/// The confirmation before a delete. Deleting a profile changes nothing but
/// this convenience: the paired device, the archive and the folders are
/// untouched.
class _DeleteDialog extends StatelessWidget {
  const _DeleteDialog({required this.row});

  final ProfileRow row;

  @override
  Widget build(BuildContext context) {
    return DestructiveConfirmDialog(
      title: 'Delete ${row.name}?',
      message:
          'This removes the saved run from the home list. It does not touch '
          'the paired device, the folders or the sync history.',
      cancelLabel: 'Cancel',
      confirmLabel: 'Delete',
      cancelKey: const Key('profiles-delete-cancel'),
      confirmKey: const Key('profiles-delete-confirm'),
    );
  }
}

/// What a row says of its last run, or `null` when there is nothing to
/// warn of.
String? _lastRunWarning(LastRun lastRun) => switch (lastRun) {
  LastRun.settled => null,
  LastRun.died =>
    'The last run did not finish. Run it again to sort out the files it '
        'left.',
  LastRun.writeHeld =>
    'A write an interrupted run was making is still held back. Run it to '
        "choose which side's copy to keep.",
};
