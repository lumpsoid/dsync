import 'package:flutter/material.dart';

import '../../format_date.dart';
import '../../paired_device_row.dart';
import 'devices_controller.dart';
import 'devices_scope.dart';

/// The home page: the paired device list (SPEC §4.4, §13). Widgets only,
/// per the page role in `app_scope.dart`: every row is a `PairedDeviceRow`
/// of already-rendered values, and the only branches here are "is there a
/// line to show" over a `String?`.
///
/// Rows come from `AppState.devices` through the controller's
/// `AppController`; this page holds no copy of them. It rebuilds on either
/// notifier — the application state for the list and the gate, the view
/// state for this page's own error line.
///
/// [onOpenDevice], [onOpenRunSetup], [onOpenPair] and [onOpenThisDevice]
/// are the seams to the features a tap leads to: the device's own page for
/// managing it, Run setup for syncing with it, Pair from either the app-bar
/// action or the empty state's button, and this installation's own identity
/// from the app bar. Each takes the destination as an id (or nothing)
/// rather than a row — the destination loads what it needs — and all are
/// the entrypoint's to wire to routes, so this page needs no `Navigator` of
/// its own.
class DevicesPage extends StatelessWidget {
  const DevicesPage({
    super.key,
    required this.onOpenDevice,
    required this.onOpenRunSetup,
    required this.onOpenPair,
    required this.onOpenThisDevice,
  });

  /// Opens the tapped device's own page — its certificate, the folders it
  /// may reach, its name here — by id.
  final void Function(String deviceId) onOpenDevice;

  /// Opens Run setup for a device, by id.
  final void Function(String deviceId) onOpenRunSetup;

  /// Opens the Pair page. Reached from the app-bar action at any list
  /// length, and from the empty state's button on a first run.
  final VoidCallback onOpenPair;

  /// Opens the This device page, where this installation's own identity is
  /// shown and its certificate renewed.
  final VoidCallback onOpenThisDevice;

  @override
  Widget build(BuildContext context) {
    final controller = devicesScope.controller;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Devices'),
        actions: [
          IconButton(
            key: const Key('devices-open-this-device'),
            icon: const Icon(Icons.badge_outlined),
            tooltip: 'This device',
            onPressed: onOpenThisDevice,
          ),
          IconButton(
            key: const Key('devices-open-pair'),
            icon: const Icon(Icons.add),
            tooltip: 'Pair a device',
            onPressed: onOpenPair,
          ),
        ],
      ),
      body: ListenableBuilder(
        listenable: Listenable.merge([controller.app.state, controller.state]),
        builder: (context, _) => _DevicesBody(
          controller: controller,
          onOpenDevice: onOpenDevice,
          onOpenRunSetup: onOpenRunSetup,
          onOpenPair: onOpenPair,
        ),
      ),
    );
  }
}

class _DevicesBody extends StatelessWidget {
  const _DevicesBody({
    required this.controller,
    required this.onOpenDevice,
    required this.onOpenRunSetup,
    required this.onOpenPair,
  });

  final DevicesController controller;
  final void Function(String deviceId) onOpenDevice;
  final void Function(String deviceId) onOpenRunSetup;
  final VoidCallback onOpenPair;

  @override
  Widget build(BuildContext context) {
    final devices = controller.app.state.devices;
    final error = controller.state.error;
    final ownWarning = controller.ownCertificateWarning;
    return RefreshIndicator(
      onRefresh: controller.refresh,
      child: ListView(
        // Scrollable even when short, so pull-to-refresh works on an empty
        // or one-row list.
        physics: const AlwaysScrollableScrollPhysics(),
        children: [
          if (error != null) _NoticeTile(error, isError: true),
          if (ownWarning != null) _NoticeTile(ownWarning, isError: false),
          if (devices.isEmpty)
            _EmptyState(onOpenPair: onOpenPair)
          else
            for (final row in devices)
              _DeviceTile(
                row: row,
                onTap: () => onOpenDevice(row.deviceId),
                onRunSetup: () => onOpenRunSetup(row.deviceId),
                onRevoke: () => _confirmRevoke(context, row),
              ),
        ],
      ),
    );
  }

  Future<void> _confirmRevoke(BuildContext context, PairedDeviceRow row) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => _RevokeDialog(row: row),
    );
    if (confirmed ?? false) await controller.revoke(row.deviceId);
  }
}

/// An error or warning line above the list, in the theme's colour for it.
class _NoticeTile extends StatelessWidget {
  const _NoticeTile(this.message, {required this.isError});

  final String message;
  final bool isError;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ListTile(
      leading: Icon(
        isError ? Icons.error_outline : Icons.warning_amber_outlined,
        color: isError ? scheme.error : scheme.tertiary,
      ),
      title: Text(message),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.onOpenPair});

  final VoidCallback onOpenPair;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(32),
      child: Column(
        children: [
          const Text('No paired devices.'),
          const SizedBox(height: 16),
          FilledButton(
            onPressed: onOpenPair,
            child: const Text('Pair a device'),
          ),
        ],
      ),
    );
  }
}

/// One paired device. The lines are ordered by how much a person can do
/// with them: the address they would recognise, when the pairing happened,
/// what it grants, any warning — and only then the grouped hex id, which is
/// how `revoke` addresses the device rather than how anyone recognises it.
/// It stays on the row (a revoke is addressed by it) but reads as a
/// footnote, in the muted label style.
///
/// Tapping anywhere on the row opens the device's own page — where its
/// certificate, the folders it may reach and its name here are managed.
/// Syncing with it is the separate, named action beside the revoke icon:
/// the two are different intents, and a row that meant both depending on
/// where it was tapped would be guessing.
class _DeviceTile extends StatelessWidget {
  const _DeviceTile({
    required this.row,
    required this.onTap,
    required this.onRunSetup,
    required this.onRevoke,
  });

  final PairedDeviceRow row;

  /// Opens the device's own page.
  final VoidCallback onTap;

  /// Opens Run setup for this device.
  final VoidCallback onRunSetup;
  final VoidCallback onRevoke;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final warning = row.certificateWarning;
    return ListTile(
      title: Text(row.name),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(row.address),
          Text('paired ${formatDate(row.pairedAt)}'),
          Text(_rootsLine(row.agreedRootCount)),
          if (warning != null)
            Text(warning, style: TextStyle(color: theme.colorScheme.tertiary)),
          Text(
            row.deviceId,
            style: theme.textTheme.labelSmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
      isThreeLine: true,
      onTap: onTap,
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextButton(onPressed: onRunSetup, child: const Text(_runSetupLabel)),
          IconButton(
            icon: const Icon(Icons.delete_outline),
            tooltip: 'Revoke',
            onPressed: onRevoke,
          ),
        ],
      ),
    );
  }
}

/// What a tap on a device row does, in the user's words.
const _runSetupLabel = 'Set up run';

/// The confirmation before a revoke. Its text carries SPEC §4.4's
/// one-sidedness in the user's words: revoking here only makes this device
/// forget the peer; the peer keeps its own entry and is told nothing.
class _RevokeDialog extends StatelessWidget {
  const _RevokeDialog({required this.row});

  final PairedDeviceRow row;

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text('Revoke ${row.name}?'),
      content: Text(
        'This device will stop trusting ${row.name} and will refuse its '
        'connections.\n\n'
        'This only changes this device. ${row.name} is not told and still '
        'trusts this device until you revoke there too.',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(true),
          child: const Text('Revoke'),
        ),
      ],
    );
  }
}

/// The agreed-roots count as a line. Zero is a line now, not a silence: the
/// head grants and withdraws roots itself, so "no folders shared" is a fact
/// about this pairing and the first thing to fix on a device that cannot
/// reach anything — it used to be structural, and saying nothing was the
/// honest answer only while nothing here could grant. Pluralisation over an
/// already-rendered count, not a rule about it.
String _rootsLine(int count) => switch (count) {
  0 => 'no folders shared',
  1 => '1 folder shared',
  _ => '$count folders shared',
};
