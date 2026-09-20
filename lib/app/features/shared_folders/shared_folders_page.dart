import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../shared_folder_row.dart';
import '../../withdraw_root_dialog.dart';
import 'shared_folders_controller.dart';
import 'shared_folders_scope.dart';
import 'shared_folders_view_state.dart';

/// The Shared folders page: everything this host serves, and to whom (SPEC
/// §4.4, §13).
///
/// The Device page is per-device — "what may this peer reach here". This is
/// the same store read the other way up: one row per folder, each naming
/// the devices allowed to ask for it, with granting and withdrawing done by
/// toggling a device on that folder. Sharing one folder with four devices
/// used to be the same path typed on four pages.
///
/// Widgets only, per the page role in `app_scope.dart`: the rows are
/// [SharedFolderRow]s of rendered strings and toggle positions, and the
/// only branches here are over the sealed [SharedFoldersOutcome] and over
/// "is the list empty".
///
/// **It only ever shows this host's own grants.** A grant is one-sided and
/// told to nobody (SPEC §4.4), so nothing on this page is, or could be,
/// what a peer serves back to this device. The copy says "may reach" rather
/// than "is synced with" for that reason.
///
/// A leaf: it takes no navigation callbacks because nothing leads anywhere
/// from it.
class SharedFoldersPage extends StatelessWidget {
  const SharedFoldersPage({super.key});

  @override
  Widget build(BuildContext context) {
    final controller = sharedFoldersScope.controller;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Shared folders'),
        actions: [
          IconButton(
            key: const Key('shared-folders-add'),
            icon: const Icon(Icons.create_new_folder_outlined),
            tooltip: 'Share a folder',
            onPressed: () => _addFolder(context, controller),
          ),
        ],
      ),
      body: ListenableBuilder(
        // Both notifiers: the application state holds the devices this page
        // inverts, the view state holds this page's own outcome line.
        listenable: Listenable.merge([controller.app.state, controller.state]),
        builder: (context, _) => _SharedFoldersBody(controller: controller),
      ),
    );
  }

  /// Asks for a folder and the devices to share it with, then makes the
  /// grants. Both answers are taken in one dialog because neither is worth
  /// anything alone: a root granted to nobody is stored nowhere.
  Future<void> _addFolder(
    BuildContext context,
    SharedFoldersController controller,
  ) async {
    final share = await showDialog<_NewShare>(
      context: context,
      builder: (context) => _AddFolderDialog(
        devices: controller.devicesForNewFolder,
        onBrowse: controller.chooseFolder,
      ),
    );
    if (share != null) {
      await controller.shareNewFolder(share.path, share.deviceIds);
    }
  }
}

class _SharedFoldersBody extends StatelessWidget {
  const _SharedFoldersBody({required this.controller});

  final SharedFoldersController controller;

  @override
  Widget build(BuildContext context) {
    final folders = controller.folders;
    final hasDevices = controller.devicesForNewFolder.isNotEmpty;
    return ListView(
      children: [
        switch (controller.state.outcome) {
          SharedFoldersDone(:final message) => _NoticeTile(
            message,
            isError: false,
          ),
          SharedFoldersFailed(:final message) => _NoticeTile(
            message,
            isError: true,
          ),
          SharedFoldersIdle() => const SizedBox.shrink(),
        },
        if (!hasDevices)
          const _EmptyState(
            key: Key('shared-folders-no-devices'),
            message:
                'No paired devices. A folder is shared with a device, so '
                'there is nothing to share until one is paired.',
          )
        else if (folders.isEmpty)
          const _EmptyState(
            key: Key('shared-folders-empty'),
            message:
                'This device shares no folders. Paired devices can reach '
                'nothing here until a folder is added.',
          )
        else
          for (final folder in folders)
            _FolderSection(folder: folder, controller: controller),
        const _Explanation(),
      ],
    );
  }
}

/// One folder, and every paired device's toggle on it.
///
/// The folder leads and the devices sit under it, because that ordering is
/// the whole point of this page: the question here is "who may reach this",
/// and the same facts read device-first are already on the Device page.
class _FolderSection extends StatelessWidget {
  const _FolderSection({required this.folder, required this.controller});

  final SharedFolderRow folder;
  final SharedFoldersController controller;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final note = folder.note;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ListTile(
          key: Key('shared-folder-${folder.rootPath}'),
          leading: const Icon(Icons.folder_shared_outlined),
          title: Text(folder.label, overflow: TextOverflow.ellipsis),
          subtitle: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(folder.reachSummary),
              if (note != null)
                Text(note, style: TextStyle(color: theme.colorScheme.tertiary)),
            ],
          ),
          isThreeLine: note != null,
          trailing: IconButton(
            key: Key('shared-folder-copy-${folder.rootPath}'),
            icon: const Icon(Icons.copy_outlined),
            tooltip: 'Copy folder path',
            onPressed: () => _copyPath(context),
          ),
        ),
        for (final device in folder.devices)
          SwitchListTile(
            key: Key('shared-folder-${folder.rootPath}-${device.deviceId}'),
            value: device.isShared,
            title: Text(device.name),
            onChanged: (wanted) => _toggle(context, device, wanted: wanted),
          ),
        const Divider(),
      ],
    );
  }

  /// Copies the stored path, not the elided label: the label is what fits
  /// on a phone row, and what a person pastes into a shell or into the other
  /// host's add-folder field has to be the path the store holds byte for
  /// byte. Reading a long path off a screen and retyping it is the one way
  /// to make two hosts disagree about which folder was shared.
  Future<void> _copyPath(BuildContext context) async {
    final messenger = ScaffoldMessenger.of(context);
    await Clipboard.setData(ClipboardData(text: folder.rootPath));
    messenger.showSnackBar(
      const SnackBar(content: Text('Folder path copied.')),
    );
  }

  /// Toggling on is a grant and happens immediately — it widens nothing
  /// that was not already paired, and an accidental one is undone by the
  /// same switch. Toggling off is destructive and asks first, through the
  /// same [WithdrawRootDialog] the Device page asks with: it is the same
  /// write, and two dialogs about it would be two chances to say something
  /// different.
  Future<void> _toggle(
    BuildContext context,
    SharedFolderDevice device, {
    required bool wanted,
  }) async {
    if (wanted) {
      await controller.share(device.deviceId, folder.rootPath);
      return;
    }
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) =>
          WithdrawRootDialog(rootLabel: folder.label, deviceName: device.name),
    );
    if (confirmed ?? false) {
      await controller.withdraw(device.deviceId, folder.rootPath);
    }
  }
}

/// A folder to share and the devices to share it with, as the dialog hands
/// them back. Both together: granting a folder to nobody writes nothing,
/// so the page never asks the controller to.
class _NewShare {
  const _NewShare({required this.path, required this.deviceIds});

  final String path;
  final List<String> deviceIds;
}

/// The add flow: choose (or type) a folder, tick the devices that may reach
/// it, share.
///
/// The chooser leads and is the filled button, for the reason the Device
/// page's grant dialog gives: choosing is right for almost every grant, and
/// a typed path is a chance to misspell something nobody will be told was
/// wrong. Unlike that dialog, a chosen folder does *not* close this one —
/// there are still devices to tick, and the choice is only half the answer.
///
/// Typing stays, because the chooser cannot answer every case: a folder on
/// a desktop this phone only manages the store for, or a root that does not
/// exist yet on the host that will serve it. A grant is authorization, not
/// reachability, and nothing here probes the folder.
class _AddFolderDialog extends StatefulWidget {
  const _AddFolderDialog({required this.devices, required this.onBrowse});

  /// Every paired device, toggles off — the list to tick.
  final List<SharedFolderDevice> devices;

  /// Opens the platform chooser and returns what was picked. Taken as a
  /// callback rather than reached for here, so a widget test drives this
  /// dialog without a platform channel.
  final Future<String?> Function() onBrowse;

  @override
  State<_AddFolderDialog> createState() => _AddFolderDialogState();
}

class _AddFolderDialogState extends State<_AddFolderDialog> {
  final TextEditingController _path = TextEditingController();
  final Set<String> _chosen = <String>{};

  @override
  void dispose() {
    _path.dispose();
    super.dispose();
  }

  Future<void> _browse() async {
    final picked = await widget.onBrowse();
    if (picked != null) _path.text = picked;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AlertDialog(
      title: const Text('Share a folder'),
      content: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            FilledButton.icon(
              key: const Key('shared-folders-browse'),
              onPressed: _browse,
              icon: const Icon(Icons.folder_open),
              label: const Text('Choose folder'),
            ),
            const SizedBox(height: 16),
            Text(
              'Or type a path — a folder that does not exist here yet can '
              'still be authorized.',
              style: theme.textTheme.bodySmall,
            ),
            TextField(
              key: const Key('shared-folders-path-field'),
              controller: _path,
              decoration: const InputDecoration(
                labelText: 'Folder on this device',
                hintText: '~/Sync',
              ),
            ),
            const SizedBox(height: 16),
            Text('Devices that may reach it', style: theme.textTheme.bodySmall),
            for (final device in widget.devices)
              CheckboxListTile(
                key: Key('shared-folders-pick-${device.deviceId}'),
                value: _chosen.contains(device.deviceId),
                title: Text(device.name),
                onChanged: (checked) => setState(() {
                  if (checked ?? false) {
                    _chosen.add(device.deviceId);
                  } else {
                    _chosen.remove(device.deviceId);
                  }
                }),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const Key('shared-folders-add-confirm'),
          onPressed: () => Navigator.of(context)
              .pop(_NewShare(path: _path.text, deviceIds: _chosen.toList())),
          child: const Text('Share'),
        ),
      ],
    );
  }
}

/// An error or confirmation line above the list, in the theme's colour for
/// it.
class _NoticeTile extends StatelessWidget {
  const _NoticeTile(this.message, {required this.isError});

  final String message;
  final bool isError;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ListTile(
      key: const Key('shared-folders-notice'),
      leading: Icon(
        isError ? Icons.error_outline : Icons.info_outline,
        color: isError ? scheme.error : scheme.tertiary,
      ),
      title: Text(message),
    );
  }
}

/// What there is to say when the page has no rows — which of the two
/// reasons it is, in the user's words.
class _EmptyState extends StatelessWidget {
  const _EmptyState({super.key, required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(32),
      child: Text(message, textAlign: TextAlign.center),
    );
  }
}

/// What a grant is, under the list rather than only inside a dialog: it is
/// the thing a user arrives here uncertain about, and reading it should not
/// require tapping a toggle first.
class _Explanation extends StatelessWidget {
  const _Explanation();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 24, 16, 32),
      child: Text(
        'These are folders on this device that paired devices are allowed '
        'to ask for. Pairing and authorizing are separate steps: a paired '
        'device reaches nothing here until a folder is shared with it, and '
        'it is never told what it may reach — it finds out by asking.\n\n'
        'What another device shares back with this one is its own decision, '
        'made there, and is not shown here.',
        style: theme.textTheme.bodySmall?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }
}
