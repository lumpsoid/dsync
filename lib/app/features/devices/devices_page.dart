import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../paired_device_row.dart';
import '../../readable_width.dart';
import '../../refresh_action.dart';
import '../../row_actions_menu.dart';
import 'device_row_actions.dart';
import 'devices_chrome.dart';
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
/// state for this page's own error line — and refreshes on pull, on the
/// app-bar [RefreshButton] or on F5 ([RefreshShortcuts]).
///
/// [onOpenDevice], [onOpenRunSetup], [onOpenPair] and the callbacks in
/// [chrome] are the seams to the features a tap leads to: the device's own
/// page for managing it, Run setup for syncing with it, Pair from either
/// the app-bar action or the empty state's button, and this installation's
/// own identity and everything it shares from the app bar.
/// Each takes the destination as an id (or nothing) rather than a row — the
/// destination loads what it needs — and all are the entrypoint's to wire
/// to routes, so this page needs no `Navigator` of its own.
///
/// [chrome] says whether This device and Shared folders are in this page's
/// app bar or, on a wide window, destinations of the app shell's rail — and
/// whether the list is the left pane of two, marking the device selected
/// beside it and moving that selection with Up and Down.
class DevicesPage extends StatelessWidget {
  const DevicesPage({
    super.key,
    required this.onOpenDevice,
    required this.onOpenRunSetup,
    required this.onOpenPair,
    required this.chrome,
  });

  /// Opens the tapped device's own page — its certificate, the folders it
  /// may reach, its name here — by id.
  final void Function(String deviceId) onOpenDevice;

  /// Opens Run setup for a device, by id.
  final void Function(String deviceId) onOpenRunSetup;

  /// Opens the Pair page. Reached from the app-bar action at any list
  /// length, and from the empty state's button on a first run.
  final VoidCallback onOpenPair;

  /// Whether this page draws its own way to This device and Shared
  /// folders, or the shell draws them.
  final DevicesChrome chrome;

  @override
  Widget build(BuildContext context) {
    final controller = devicesScope.controller;
    final chrome = this.chrome;
    return RefreshShortcuts(
      onRefresh: controller.refresh,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Devices'),
          actions: [
            RefreshButton(
              key: const Key('devices-refresh'),
              onRefresh: controller.refresh,
            ),
            if (chrome is DevicesOwnChrome) ...[
              IconButton(
                key: const Key('devices-open-shared-folders'),
                icon: const Icon(Icons.folder_shared_outlined),
                tooltip: 'Shared folders',
                onPressed: chrome.onOpenSharedFolders,
              ),
              IconButton(
                key: const Key('devices-open-this-device'),
                icon: const Icon(Icons.badge_outlined),
                tooltip: 'This device',
                onPressed: chrome.onOpenThisDevice,
              ),
            ],
            IconButton(
              key: const Key('devices-open-pair'),
              icon: const Icon(Icons.add),
              tooltip: 'Pair a device',
              onPressed: onOpenPair,
            ),
          ],
        ),
        body: ListenableBuilder(
          listenable: Listenable.merge([
            controller.app.state,
            controller.state,
          ]),
          builder: (context, _) => _DevicesBody(
            controller: controller,
            chrome: chrome,
            onOpenDevice: onOpenDevice,
            onOpenRunSetup: onOpenRunSetup,
            onOpenPair: onOpenPair,
          ),
        ),
      ),
    );
  }
}

/// The list itself. Stateful only for the keyboard: beside a device's page
/// ([DevicesBesideDetailChrome]) focus follows the selection from row to
/// row, so each row's focus is kept here by device id.
class _DevicesBody extends StatefulWidget {
  const _DevicesBody({
    required this.controller,
    required this.chrome,
    required this.onOpenDevice,
    required this.onOpenRunSetup,
    required this.onOpenPair,
  });

  final DevicesController controller;
  final DevicesChrome chrome;
  final void Function(String deviceId) onOpenDevice;
  final void Function(String deviceId) onOpenRunSetup;
  final VoidCallback onOpenPair;

  @override
  State<_DevicesBody> createState() => _DevicesBodyState();
}

class _DevicesBodyState extends State<_DevicesBody> {
  /// Each row's focus, by device id. A node outlives a revoked row until
  /// this page goes: a list of paired devices is short, and disposing a
  /// node in the frame its row is still unmounting in would pull it from
  /// under the row.
  final _rowFocus = <String, FocusNode>{};

  FocusNode _focusOf(String deviceId) => _rowFocus.putIfAbsent(
    deviceId,
    () => FocusNode(debugLabel: 'device row $deviceId'),
  );

  @override
  void dispose() {
    for (final node in _rowFocus.values) {
      node.dispose();
    }
    super.dispose();
  }

  /// Selects [deviceId] beside the list and puts focus on its row, so the
  /// next Up or Down moves on from there whether the row was clicked or
  /// reached by key.
  FocusNode _select(String deviceId) {
    widget.onOpenDevice(deviceId);
    return _focusOf(deviceId)..requestFocus();
  }

  /// Up or Down beside a device's page: from the row with focus when a row
  /// has it (a user who tabbed down the list moves on from where they are),
  /// else from the selection.
  void _step(String? selectedDeviceId, int step) {
    String? from = selectedDeviceId;
    for (final MapEntry(key: deviceId, value: node) in _rowFocus.entries) {
      if (node.hasPrimaryFocus) from = deviceId;
    }
    final next = widget.controller.deviceBeside(from, step);
    if (next == null) return;
    final node = _select(next);
    // Scrolled to once the row is laid out: its bottom edge into view
    // moving down, its top moving up, and nothing when it is in view.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final row = node.context;
      if (row == null || !row.mounted) return;
      Scrollable.ensureVisible(
        row,
        alignmentPolicy: step < 0
            ? ScrollPositionAlignmentPolicy.keepVisibleAtStart
            : ScrollPositionAlignmentPolicy.keepVisibleAtEnd,
      );
    });
  }

  /// [row]'s tile: marked and focus-following beside a device's page, a
  /// plain link to the device's page everywhere else.
  Widget _tileFor(PairedDeviceRow row, String? savedRunLine) {
    final (bool selected, VoidCallback onTap) = switch (widget.chrome) {
      DevicesBesideDetailChrome(:final selectedDeviceId) => (
        row.deviceId == selectedDeviceId,
        () => _select(row.deviceId),
      ),
      DevicesOwnChrome() ||
      DevicesShellChrome() => (false, () => widget.onOpenDevice(row.deviceId)),
    };
    return _DeviceTile(
      row: row,
      savedRunLine: savedRunLine,
      selected: selected,
      focusNode: _focusOf(row.deviceId),
      onTap: onTap,
      onRunSetup: () => widget.onOpenRunSetup(row.deviceId),
    );
  }

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    final devices = controller.app.state.devices;
    final error = controller.state.error;
    final ownWarning = controller.ownCertificateWarning;
    final savedRunLines = controller.savedRunLines;
    final list = RefreshIndicator(
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
            if (error != null) _NoticeTile(error, isError: true),
            if (ownWarning != null) _NoticeTile(ownWarning, isError: false),
            if (devices.isEmpty)
              _EmptyState(onOpenPair: widget.onOpenPair)
            else
              for (final row in devices)
                _tileFor(row, savedRunLines[row.deviceId]),
          ],
        ),
      ),
    );
    return switch (widget.chrome) {
      DevicesBesideDetailChrome(:final selectedDeviceId) => CallbackShortcuts(
        bindings: {
          const SingleActivator(LogicalKeyboardKey.arrowUp): () =>
              _step(selectedDeviceId, -1),
          const SingleActivator(LogicalKeyboardKey.arrowDown): () =>
              _step(selectedDeviceId, 1),
        },
        child: list,
      ),
      DevicesOwnChrome() || DevicesShellChrome() => list,
    };
  }
}

/// An error or warning line above the list, in the theme's colour for it.
class _NoticeTile extends StatelessWidget {
  const _NoticeTile(this.message, {required this.isError});

  final String message;
  final bool isError;

  @override
  Widget build(BuildContext context) {
    // Selectable on its own, the rows around it left out: they answer
    // clicks (`CopyValueButton` states the rule), and this line is the one
    // on the page worth pasting into a bug report.
    final scheme = Theme.of(context).colorScheme;
    return SelectionArea(
      child: ListTile(
        leading: Icon(
          isError ? Icons.error_outline : Icons.warning_amber_outlined,
          color: isError ? scheme.error : scheme.tertiary,
        ),
        title: Text(message),
      ),
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
/// device, noticing something wrong with it, knowing whether it is already
/// wired into saved runs, and starting a run with it. So the row carries
/// the name, the address it answers on, how many saved runs name it when
/// any do, a certificate warning when there is one, "no folders shared"
/// when the pairing grants nothing, and the named run action — nothing
/// else.
///
/// Everything dropped from here (when the pairing happened, the grouped hex
/// id, the folders themselves, the revoke) is on the device's own page,
/// which a tap opens. A list row that repeats a detail page costs every
/// reader height and attention on every scroll to save one tap for the rare
/// reader who wanted it.
///
/// **The saved-run count earns its line against that rule** because it is
/// not on the detail page and is not derivable from anything else on
/// screen: the saved runs live on the home list, keyed by device id, and a
/// device's own page says nothing about them. It is also what "Set up run"
/// next to it is missing — whether this is a first run with the device or
/// the fourth — and what makes revoking it a decision rather than a guess.
/// It is a line and not a trailing figure because the trailing slot is the
/// run action, and a bare number beside a button reads as part of it.
///
/// Zero renders nothing at all. A count of none says only what the run
/// action already says, and a first-run device would otherwise carry a line
/// on every row saying so. [savedRunLine] is therefore `null` rather than
/// "no saved runs", decided in `DevicesController.savedRunLines` — the join
/// over both of `AppState`'s lists — and never counted here.
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
    required this.savedRunLine,
    required this.selected,
    required this.focusNode,
    required this.onTap,
    required this.onRunSetup,
  });

  final PairedDeviceRow row;

  /// How many saved runs name this device, already rendered, or `null`
  /// when none do.
  final String? savedRunLine;

  /// Whether this is the device whose page is beside the list. Marked in
  /// the colour the shell's rail marks its selected destination with, so
  /// the two selections on screen read as the same kind of thing.
  final bool selected;

  /// The row's own focus, which the list moves along with the selection.
  final FocusNode focusNode;

  /// Opens the device's own page.
  final VoidCallback onTap;

  /// Opens Run setup for this device.
  final VoidCallback onRunSetup;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final warning = row.certificateWarning;
    final savedRuns = savedRunLine;
    final sharesNothing = row.agreedRootCount == 0;
    return RowActionsMenu(
      actions: deviceRowActions(row, onRunSetup: onRunSetup),
      focusNode: focusNode,
      handle: null,
      child: ListTile(
        // The name, and — only once the user has confirmed this device's id —
        // a mark beside it. Inline rather than in the tile's leading slot, so
        // the unconfirmed rows around it are not indented past an empty
        // square: an unconfirmed pairing is the ordinary state and costs
        // nothing on screen, which is the whole point of the confirmation
        // being optional.
        title: Row(
          children: [
            Flexible(child: Text(row.name, overflow: TextOverflow.ellipsis)),
            if (row.isVerified) ...[
              const SizedBox(width: 6),
              Icon(
                Icons.verified,
                key: Key('device-verified-${row.deviceId}'),
                size: 16,
                color: theme.colorScheme.primary,
                semanticLabel: 'Device id confirmed',
              ),
            ],
          ],
        ),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(row.address),
            if (savedRuns != null) Text(savedRuns),
            if (warning != null)
              Text(
                warning,
                style: TextStyle(color: theme.colorScheme.tertiary),
              ),
            if (sharesNothing)
              Text(
                _noRootsLine,
                style: TextStyle(color: theme.colorScheme.tertiary),
              ),
          ],
        ),
        // Two lines normally; a third only when a further line is showing.
        isThreeLine: savedRuns != null || warning != null || sharesNothing,
        selected: selected,
        selectedTileColor: theme.colorScheme.secondaryContainer,
        selectedColor: theme.colorScheme.onSecondaryContainer,
        focusNode: focusNode,
        onTap: onTap,
        trailing: TextButton(
          onPressed: onRunSetup,
          child: const Text(deviceRunSetupLabel),
        ),
      ),
    );
  }
}

/// The one roots fact a list row keeps. A pairing that grants nothing can
/// reach nothing, so a run against it fails with nothing else visibly wrong
/// — the head grants and withdraws roots itself, so this is fixable from
/// here. Counts above zero are not a warning and belong on the device's own
/// page with the roots themselves.
const _noRootsLine = 'no folders shared';
