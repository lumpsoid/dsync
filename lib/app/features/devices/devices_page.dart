import 'package:flutter/material.dart';

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
/// [onOpenRunSetup] and [onOpenPair] are the seams to the two features a
/// tap leads to: Run setup for a device, Pair from the empty state. Both
/// take the destination as an id (or nothing) rather than a row — the
/// destination loads what it needs — and both are the entrypoint's to wire
/// to routes, so this page needs no `Navigator` of its own.
class DevicesPage extends StatelessWidget {
  const DevicesPage({
    super.key,
    required this.onOpenRunSetup,
    required this.onOpenPair,
  });

  /// Opens Run setup for the tapped device, by id.
  final void Function(String deviceId) onOpenRunSetup;

  /// Opens the Pair page, from the empty state.
  final VoidCallback onOpenPair;

  @override
  Widget build(BuildContext context) {
    final controller = devicesScope.controller;
    return Scaffold(
      appBar: AppBar(title: const Text('Devices')),
      body: ListenableBuilder(
        listenable: Listenable.merge([controller.app.state, controller.state]),
        builder: (context, _) => _DevicesBody(
          controller: controller,
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
    required this.onOpenRunSetup,
    required this.onOpenPair,
  });

  final DevicesController controller;
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
                onTap: () => onOpenRunSetup(row.deviceId),
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

class _DeviceTile extends StatelessWidget {
  const _DeviceTile({
    required this.row,
    required this.onTap,
    required this.onRevoke,
  });

  final PairedDeviceRow row;
  final VoidCallback onTap;
  final VoidCallback onRevoke;

  @override
  Widget build(BuildContext context) {
    final warning = row.certificateWarning;
    return ListTile(
      title: Text(row.name),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(row.deviceId),
          Text(row.address),
          Text('paired ${_formatPairedAt(row.pairedAt)}'),
          Text(_rootsLine(row.agreedRootCount)),
          if (warning != null)
            Text(
              warning,
              style: TextStyle(color: Theme.of(context).colorScheme.tertiary),
            ),
        ],
      ),
      isThreeLine: true,
      onTap: onTap,
      trailing: IconButton(
        icon: const Icon(Icons.delete_outline),
        tooltip: 'Revoke',
        onPressed: onRevoke,
      ),
    );
  }
}

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

/// `pairedAt` as a local calendar date. A locale question the widget owns
/// (see `PairedDeviceRow.pairedAt`), kept to the date because the minute a
/// pairing happened is not something anyone acts on.
String _formatPairedAt(DateTime pairedAt) {
  final local = pairedAt.toLocal();
  String two(int n) => n.toString().padLeft(2, '0');
  return '${local.year}-${two(local.month)}-${two(local.day)}';
}

/// The agreed-roots count as a line. Zero is shown as the fact SPEC §4.4's
/// two-step rule makes it — paired but granted nothing yet — with the
/// desktop command that changes that, the way `dsync pair list` does.
/// Pluralisation over an already-rendered count, not a rule about it.
String _rootsLine(int count) => switch (count) {
  0 => 'no replica roots granted — grant one with `dsync pair grant`',
  1 => '1 replica root',
  _ => '$count replica roots',
};
