import 'package:flutter/material.dart';

import '../../profile_row.dart';
import 'profiles_controller.dart';
import 'profiles_scope.dart';

/// The home page: the saved runs (the head's home list). Widgets only, per
/// the page role in `app_scope.dart`: every row is a [ProfileRow] of
/// already-rendered values — including [ProfileRow.brokenReason], which is
/// the whole of the brokenness decision — and the only branches here are
/// "is there a line to show" over a `String?`.
///
/// Rows come from `AppState.profiles` through the controller's
/// `AppController`; this page holds no copy of them. It loads on mounting —
/// the store read that makes the list survive an app restart — rebuilds on
/// either notifier (the application state for the rows, the view state for
/// this page's own error line), and refreshes on pull.
///
/// A broken profile renders as itself, not gone: untappable, with its
/// [ProfileRow.brokenReason] where the tap summary would be. Revoking the
/// device or losing the folder must be visible from the home list, because
/// the row is the only place the run the user configured still exists.
///
/// [onOpenProfile] is the seam to Run setup, fired with the tapped row's
/// profile id — an id, not a row, per the handoff rule.
/// [onOpenDevices] is the seam to Devices, from the app bar and from the
/// empty state: pairing and revoking still need a device view, and a first
/// profile is born there. Both are the entrypoint's to wire to routes, so
/// this page needs no `Navigator` of its own.
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
                onTap: row.brokenReason == null
                    ? () => onOpenProfile(row.id)
                    : null,
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
    required this.onDelete,
  });

  final ProfileRow row;

  /// `null` on a broken profile: the row renders, but nothing about it is a
  /// tap target.
  final VoidCallback? onTap;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final broken = row.brokenReason;
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
          if (broken != null)
            Text(
              broken,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
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
