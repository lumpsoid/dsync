import 'package:flutter/material.dart';

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
  });

  /// Opens Run setup pre-filled from the tapped profile, by id — the id is
  /// the whole handoff; the destination loads what it needs.
  final void Function(String profileId) onOpenProfile;

  /// Opens the Devices page.
  final VoidCallback onOpenDevices;

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
  final void Function(String profileId) onOpenProfile;
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
                    ? () => onOpenProfile(row.id)
                    : null,
                onPickFolder: () => controller.repickLocalFolder(row.id),
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
    if (confirmed ?? false) await controller.delete(row.id);
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
    required this.onPickFolder,
    required this.onPairAgain,
    required this.onDelete,
  });

  final ProfileRow row;

  /// `null` on a broken profile: running it is what is broken, so the row
  /// is not a tap target until its remedy has been taken.
  final VoidCallback? onTap;

  /// Re-picks this profile's local folder — the remedy for
  /// [ProfileLocalRootUnusable].
  final VoidCallback onPickFolder;

  /// Opens Devices, where the revoked peer can be paired with again — the
  /// remedy for [ProfileDeviceUnpaired].
  final VoidCallback onPairAgain;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final breakage = row.breakage;
    return ListTile(
      title: Text(row.name),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '${row.localRootPath} ↔ '
            '${row.peerName ?? row.peerDeviceId}:${row.remoteRootPath}',
            overflow: TextOverflow.ellipsis,
          ),
          if (breakage != null) ...[
            Text(
              breakage.message,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
            Align(
              alignment: Alignment.centerLeft,
              child: switch (breakage) {
                ProfileLocalRootUnusable() => TextButton(
                  key: Key('profile-pick-folder-${row.id}'),
                  onPressed: onPickFolder,
                  child: const Text('Choose folder'),
                ),
                ProfileDeviceUnpaired() => TextButton(
                  key: Key('profile-pair-again-${row.id}'),
                  onPressed: onPairAgain,
                  child: const Text('Pair again'),
                ),
              },
            ),
          ],
        ],
      ),
      isThreeLine: true,
      onTap: onTap,
      trailing: IconButton(
        icon: const Icon(Icons.delete_outline),
        tooltip: 'Delete profile',
        onPressed: onDelete,
      ),
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
