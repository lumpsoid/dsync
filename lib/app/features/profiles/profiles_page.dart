import 'package:flutter/material.dart';

import '../../format_path.dart';
import '../../profile_breakage.dart';
import '../../profile_row.dart';
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
/// this page's own error line), and refreshes on pull.
///
/// A broken profile renders as itself, not gone: not a tap target, with its
/// [ProfileBreakage] message and that breakage's remedy where the tap
/// summary would be. Revoking the device or losing the folder must be
/// visible from the home list, because the row is the only place the run
/// the user configured still exists — and it must be fixable there, because
/// the alternative is deleting the run and configuring it again.
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
class ProfilesPage extends StatefulWidget {
  const ProfilesPage({
    super.key,
    required this.onOpenProfile,
    required this.onOpenDevices,
    required this.onOpenArchives,
    required this.onOpenSettings,
    required this.onOpenServe,
  });

  /// Opens Run setup pre-filled from the tapped profile, by id — the id is
  /// the whole handoff; the destination loads what it needs.
  final void Function(String profileName) onOpenProfile;

  /// Opens the Devices page.
  final VoidCallback onOpenDevices;

  /// Opens the Sync history page, where the archives are listed with what
  /// they cost and can be deleted. From the app bar only: it is maintenance,
  /// not part of setting up or making a run.
  final VoidCallback onOpenArchives;

  /// Opens the Settings page. From the app bar of the home page, because
  /// settings belong to the installation rather than to any one device,
  /// profile or run — this is the only screen every route starts from.
  final VoidCallback onOpenSettings;

  /// Opens the Serve page, where this device starts answering paired
  /// devices (SPEC §4.4). From the app bar of the home page because it is
  /// an activity the user starts — their hands are on the device that will
  /// serve — rather than a subsection of managing any one peer.
  final VoidCallback onOpenServe;

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
    return Scaffold(
      appBar: AppBar(
        title: const Text('dsync'),
        actions: [
          IconButton(
            key: const Key('profiles-open-serve'),
            icon: const Icon(Icons.wifi_tethering),
            tooltip: 'Answer paired devices',
            onPressed: widget.onOpenServe,
          ),
          IconButton(
            key: const Key('profiles-open-archives'),
            icon: const Icon(Icons.sd_storage_outlined),
            tooltip: 'Sync history',
            onPressed: widget.onOpenArchives,
          ),
          IconButton(
            key: const Key('profiles-open-settings'),
            icon: const Icon(Icons.settings_outlined),
            tooltip: 'Settings',
            onPressed: widget.onOpenSettings,
          ),
          TextButton(
            key: const Key('profiles-open-devices'),
            onPressed: widget.onOpenDevices,
            child: const Text('Devices'),
          ),
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
      floatingActionButton: FloatingActionButton.extended(
        key: const Key('profiles-new-run'),
        onPressed: widget.onOpenDevices,
        icon: const Icon(Icons.sync),
        label: const Text('New run'),
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
    final error = controller.state.error;
    return RefreshIndicator(
      onRefresh: controller.refresh,
      child: ListView(
        // Scrollable even when short, so pull-to-refresh works on an empty
        // or one-row list.
        physics: const AlwaysScrollableScrollPhysics(),
        children: [
          if (error != null) _NoticeTile(error),
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
    return ListTile(
      leading: Icon(
        Icons.error_outline,
        color: Theme.of(context).colorScheme.error,
      ),
      title: Text(message),
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
    return Card(
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
              for (final (index, entry) in _shown(row.entries).indexed) ...[
                if (index > 0) const SizedBox(height: 8),
                _PairSide(label: 'On this device', path: entry.localRootLabel),
                const SizedBox(height: 8),
                _PairSide(
                  label:
                      'On ${row.peerName ?? 'unpaired device ${row.peerDeviceId}'}',
                  path: entry.remoteRootLabel,
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
              if (row.lastRunUnfinished) ...[
                const SizedBox(height: 8),
                Text(
                  'The last run did not finish. Run it again to sort out the '
                  'files it left.',
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
    );
  }
}

/// The entries a row draws in full: the first two, so a long profile still
/// fits on a row sized for one.
List<ProfileEntryRow> _shown(List<ProfileEntryRow> entries) =>
    entries.length <= 2 ? entries : entries.sublist(0, 2);

/// One side of the pair: where it is, and the folder it is.
///
/// The path is drawn in two weights out of [PathLabel] — the parent quiet,
/// the leaf in the body colour and bolder. Every folder on a device shares
/// a long prefix, so printed at one weight the shared part is what the eye
/// lands on and the leaf, the only part that tells two saved runs apart, is
/// what it has to hunt for. Two weights put the distinguishing part first
/// in reading order without moving it in the path.
///
/// One `Text.rich`, not two `Text`s in a `Row`: the pair is one path and
/// wants one text layout, so the line breaks where a path line should and
/// the parent's elision stays the character-budget one `PathLabel` already
/// applied, with `ellipsis` as the backstop for the width a character count
/// cannot know about.
class _PairSide extends StatelessWidget {
  const _PairSide({required this.label, required this.path});

  final String label;
  final PathLabel path;

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
        Text.rich(
          TextSpan(
            children: [
              TextSpan(
                text: path.parent,
                style: TextStyle(color: theme.colorScheme.onSurfaceVariant),
              ),
              TextSpan(
                text: path.leaf,
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
            ],
            style: theme.textTheme.bodyMedium,
          ),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
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
    return AlertDialog(
      title: Text('Delete ${row.name}?'),
      content: const Text(
        'This removes the saved run from the home list. It does not touch '
        'the paired device, the folders or the sync history.',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(true),
          child: const Text('Delete'),
        ),
      ],
    );
  }
}
