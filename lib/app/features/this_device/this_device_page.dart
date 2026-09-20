import 'package:flutter/material.dart';

import '../../device_identity_row.dart';
import '../../format_date.dart';
import 'this_device_controller.dart';
import 'this_device_scope.dart';
import 'this_device_view_state.dart';

/// This installation's own identity (SPEC §4.4, §13): what it is called,
/// the id a peer pins it by, when its certificate was issued and when it
/// expires — and the two things that can be done about it.
///
/// Widgets only, per the page role in `app_scope.dart`: the identity
/// arrives as a `DeviceIdentityRow` of strings and dates, and the only
/// branches here are over that row's nullability and the sealed
/// [IdentityOutcome].
///
/// **Both actions are confirmed first, and the confirmation is the point.**
/// Renewing and renaming re-issue the same certificate at the same cost
/// (see `ThisDeviceController`), and that cost — every paired device is
/// unreachable *from here* until it has connected here once — is not
/// something a user should discover from a failed run afterwards. The
/// dialogs say it before, and the success line says it again after.
///
/// A leaf: nothing leads anywhere from this page, so it takes no callbacks.
class ThisDevicePage extends StatefulWidget {
  const ThisDevicePage({super.key});

  @override
  State<ThisDevicePage> createState() => _ThisDevicePageState();
}

class _ThisDevicePageState extends State<ThisDevicePage> {
  final ThisDeviceController _controller = thisDeviceScope.controller;

  @override
  void initState() {
    super.initState();
    _controller.loadStateDirPath();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('This device')),
      body: ListenableBuilder(
        listenable: Listenable.merge([
          _controller.app.state,
          _controller.state,
        ]),
        builder: (context, _) => _ThisDeviceBody(controller: _controller),
      ),
    );
  }
}

class _ThisDeviceBody extends StatelessWidget {
  const _ThisDeviceBody({required this.controller});

  final ThisDeviceController controller;

  @override
  Widget build(BuildContext context) {
    final identity = controller.identity;
    if (identity == null) {
      // The gate has not produced one. Reachable only if this page is
      // opened before bootstrap finished, which routing does not do; shown
      // rather than asserted, because a blank screen is a worse answer than
      // a true one.
      return const Center(child: Text('This device has no identity yet.'));
    }
    final outcome = controller.state.outcome;
    final working = outcome is IdentityWorking;
    return ListView(
      children: [
        _IdentityCard(identity),
        if (identity.certificateWarning case final warning?)
          _NoticeTile(warning, isError: false),
        switch (outcome) {
          IdentitySucceeded(:final message) => _NoticeTile(
            message,
            isError: false,
          ),
          IdentityFailed(:final message) => _NoticeTile(message, isError: true),
          IdentityIdle() || IdentityWorking() => const SizedBox.shrink(),
        },
        const Divider(),
        ListTile(
          key: const Key('this-device-rename'),
          leading: const Icon(Icons.edit_outlined),
          title: const Text('Rename this device'),
          subtitle: const Text(
            'The name offered to devices you pair with from now on. Devices '
            'already paired keep the name they gave this one.',
          ),
          enabled: !working,
          onTap: () => _rename(context, identity),
        ),
        ListTile(
          key: const Key('this-device-renew'),
          leading: const Icon(Icons.autorenew),
          title: const Text('Renew certificate'),
          subtitle: const Text(
            'Re-issue it under the same key, with a fresh expiry date. The '
            'device id does not change.',
          ),
          enabled: !working,
          onTap: () => _renew(context),
        ),
        if (working)
          const ListTile(
            title: LinearProgressIndicator(
              semanticsLabel: 'Re-issuing the certificate',
            ),
          ),
        if (controller.state.stateDirPath case final path?) _StateDirTile(path),
      ],
    );
  }

  Future<void> _renew(BuildContext context) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => const _ReissueDialog(
        title: 'Renew this device\'s certificate?',
        action: 'Renew',
      ),
    );
    if (confirmed ?? false) await controller.renew();
  }

  Future<void> _rename(BuildContext context, DeviceIdentityRow identity) async {
    final name = await showDialog<String>(
      context: context,
      builder: (context) => _RenameDialog(initialName: identity.name),
    );
    if (name != null) await controller.rename(name);
  }
}

/// The identity's facts, in the order a person reads them: the name they
/// gave it, the dates that decide whether it still works, and only then the
/// grouped hex id — which is how a peer addresses this device rather than
/// how anyone recognises it. Selectable, because reading it aloud or
/// pasting it into a `dsync pair grant` on the other machine is the whole
/// reason it is on screen.
class _IdentityCard extends StatelessWidget {
  const _IdentityCard(this.identity);

  final DeviceIdentityRow identity;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      children: [
        ListTile(
          title: Text(
            identity.name.isEmpty ? 'Unnamed device' : identity.name,
            style: theme.textTheme.titleLarge,
          ),
          subtitle: Text(
            'issued ${formatDate(identity.issuedAt)} · '
            'expires ${formatDate(identity.expiresAt)}',
          ),
        ),
        ListTile(
          title: const Text('Device id'),
          subtitle: SelectableText(
            identity.deviceId,
            key: const Key('this-device-id'),
            style: theme.textTheme.bodyMedium,
          ),
        ),
      ],
    );
  }
}

/// Where the identity, the pairings and the archives are on disk.
/// Selectable for the same reason the id is: the next thing a user does
/// with a path is type it somewhere else.
class _StateDirTile extends StatelessWidget {
  const _StateDirTile(this.path);

  final String path;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListTile(
      leading: const Icon(Icons.folder_outlined),
      title: const Text('State directory'),
      subtitle: SelectableText(
        path,
        key: const Key('this-device-state-dir'),
        style: theme.textTheme.bodySmall?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }
}

/// An error, warning or confirmation line, in the theme's colour for it.
class _NoticeTile extends StatelessWidget {
  const _NoticeTile(this.message, {required this.isError});

  final String message;
  final bool isError;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ListTile(
      leading: Icon(
        isError ? Icons.error_outline : Icons.info_outline,
        color: isError ? scheme.error : scheme.tertiary,
      ),
      title: Text(message),
    );
  }
}

/// What a re-issue costs, said before it happens. The same words for both
/// actions, because it is the same write: see `ThisDeviceController`.
class _ReissueDialog extends StatelessWidget {
  const _ReissueDialog({required this.title, required this.action});

  final String title;
  final String action;

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(title),
      content: const Text(
        'This device keeps its id, so every pairing survives.\n\n'
        'Paired devices pick the new certificate up the next time they '
        'connect to this device. Until each has, runs started from here to '
        'that device are refused.',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(true),
          child: Text(action),
        ),
      ],
    );
  }
}

/// The new name, and the same warning the renew dialog carries — renaming
/// re-issues the certificate, so it costs what renewing costs. Pops the
/// typed name, or nothing at all when cancelled; the empty-name refusal is
/// the controller's, so there is one rule about it rather than two.
class _RenameDialog extends StatefulWidget {
  const _RenameDialog({required this.initialName});

  final String initialName;

  @override
  State<_RenameDialog> createState() => _RenameDialogState();
}

class _RenameDialogState extends State<_RenameDialog> {
  late final TextEditingController _name = TextEditingController(
    text: widget.initialName,
  );

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Rename this device'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            key: const Key('this-device-name-field'),
            controller: _name,
            autofocus: true,
            decoration: const InputDecoration(labelText: 'Name'),
            onSubmitted: (value) => Navigator.of(context).pop(value),
          ),
          const SizedBox(height: 16),
          const Text(
            'The name lives in this device\'s certificate, so renaming '
            're-issues it. The device id does not change, but paired devices '
            'must connect here once before this device can reach them again.',
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const Key('this-device-rename-confirm'),
          onPressed: () => Navigator.of(context).pop(_name.text),
          child: const Text('Rename'),
        ),
      ],
    );
  }
}
