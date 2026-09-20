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
              ),
        ],
      ),
    );
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

/// One paired device, cut down to what a list row is for: recognising the
/// device, noticing something wrong with it, and starting a run with it.
/// So the row carries the name, the address it answers on, a certificate
/// warning when there is one, "no folders shared" when the pairing grants
/// nothing, and the named run action — nothing else.
///
/// Everything dropped from here (when the pairing happened, the grouped hex
/// id, the folders themselves, the revoke) is on the device's own page,
/// which a tap opens. A list row that repeats a detail page costs every
/// reader height and attention on every scroll to save one tap for the rare
/// reader who wanted it.
///
/// "No folders shared" stays because it is not a detail: it is the reason a
/// run against a perfectly healthy-looking pairing finds nothing, and it is
/// invisible anywhere else in the list. It is rendered only at zero and in
/// the warning colour, beside the certificate warning, because both say the
/// same thing — this pairing needs attention before a run.
///
/// Revoking is deliberately not here. It sat one mis-tap from "Set up run"
/// on a dense row; it lives on the device's page, behind a confirmation.
class _DeviceTile extends StatelessWidget {
  const _DeviceTile({
    required this.row,
    required this.onTap,
    required this.onRunSetup,
  });

  final PairedDeviceRow row;

  /// Opens the device's own page.
  final VoidCallback onTap;

  /// Opens Run setup for this device.
  final VoidCallback onRunSetup;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final warning = row.certificateWarning;
    final sharesNothing = row.agreedRootCount == 0;
    return ListTile(
      title: Text(row.name),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(row.address),
          if (warning != null)
            Text(warning, style: TextStyle(color: theme.colorScheme.tertiary)),
          if (sharesNothing)
            Text(
              _noRootsLine,
              style: TextStyle(color: theme.colorScheme.tertiary),
            ),
        ],
      ),
      // Two lines normally; a third only when a warning line is showing.
      isThreeLine: warning != null || sharesNothing,
      onTap: onTap,
      trailing: TextButton(
        onPressed: onRunSetup,
        child: const Text(_runSetupLabel),
      ),
    );
  }
}

/// What a tap on a device row does, in the user's words.
const _runSetupLabel = 'Set up run';

/// The one roots fact a list row keeps. A pairing that grants nothing can
/// reach nothing, so a run against it fails with nothing else visibly wrong
/// — the head grants and withdraws roots itself, so this is fixable from
/// here. Counts above zero are not a warning and belong on the device's own
/// page with the roots themselves.
const _noRootsLine = 'no folders shared';
