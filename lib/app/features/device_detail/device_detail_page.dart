import 'package:flutter/material.dart';

import '../../format_date.dart';
import '../../paired_device_row.dart';
import '../../withdraw_root_dialog.dart';
import 'device_detail_controller.dart';
import 'device_detail_scope.dart';
import 'device_detail_view_state.dart';

/// One paired device, and everything this host decides about it (SPEC §4.4,
/// §13): its name here, the certificate this host pins it by, the replica
/// roots it may reach, and whether it is trusted at all.
///
/// Widgets only, per the page role in `app_scope.dart`: the device arrives
/// as a `PairedDeviceRow` of strings, counts and dates, and the branches
/// here are over that row's absence and the sealed [DeviceDetailOutcome].
///
/// **Opened by id, not by row** — the handoff rule. The controller reads
/// the row back out of `AppState.devices`, so a rename made here shows
/// immediately and a device revoked here (or elsewhere) empties the page
/// instead of leaving a row that no longer exists on screen.
///
/// [onGone] is the seam back: it fires once the device this page was opened
/// for is no longer paired, which is what a revoke produces. The page does
/// not pop itself — it has no `Navigator` of its own, per this head's
/// navigation rule — and the entrypoint wires it to one.
class DeviceDetailPage extends StatefulWidget {
  const DeviceDetailPage({
    super.key,
    required this.deviceId,
    required this.onGone,
  });

  /// Which device this page is about — the whole of the handoff.
  final String deviceId;

  /// Called when the device stops being paired, so the route that pushed
  /// this page can leave it.
  final VoidCallback onGone;

  @override
  State<DeviceDetailPage> createState() => _DeviceDetailPageState();
}

class _DeviceDetailPageState extends State<DeviceDetailPage> {
  final DeviceDetailController _controller = deviceDetailScope.controller;

  @override
  void initState() {
    super.initState();
    _controller.select(widget.deviceId);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(_controller.device?.name ?? 'Device')),
      body: ListenableBuilder(
        listenable: Listenable.merge([
          _controller.app.state,
          _controller.state,
        ]),
        builder: (context, _) =>
            _DeviceDetailBody(controller: _controller, onGone: widget.onGone),
      ),
    );
  }
}

class _DeviceDetailBody extends StatelessWidget {
  const _DeviceDetailBody({required this.controller, required this.onGone});

  final DeviceDetailController controller;
  final VoidCallback onGone;

  @override
  Widget build(BuildContext context) {
    final device = controller.device;
    if (device == null) {
      // Revoked — here, or in another window against the same store. The
      // page has nothing left to show, so it says so and offers the way
      // back rather than popping under the user's finger.
      return _Gone(onGone: onGone);
    }
    final confirmedAt = device.verifiedAt;
    return ListView(
      children: [
        _IdentityTile(device),
        if (device.certificateWarning case final warning?)
          _NoticeTile(warning, isError: false),
        switch (controller.state.outcome) {
          DeviceDetailDone(:final message) => _NoticeTile(
            message,
            isError: false,
          ),
          DeviceDetailFailed(:final message) => _NoticeTile(
            message,
            isError: true,
          ),
          DeviceDetailIdle() => const SizedBox.shrink(),
        },
        const Divider(),
        ListTile(
          key: const Key('device-rename'),
          leading: const Icon(Icons.edit_outlined),
          title: const Text('Rename'),
          subtitle: const Text(
            'What this device is called here. The other device is not told '
            'and keeps its own name for this one.',
          ),
          onTap: () => _rename(context, device),
        ),
        ListTile(
          key: const Key('device-address'),
          leading: const Icon(Icons.wifi_tethering),
          title: const Text('Address'),
          subtitle: const Text(
            'Where this device is reached. Correct it here when it has '
            'moved, and it is remembered — there is no need to re-enter it '
            'for each run.',
          ),
          onTap: () => _editAddress(context, device),
        ),
        ListTile(
          key: const Key('device-test-connection'),
          leading: const Icon(Icons.network_check),
          title: const Text('Test connection'),
          subtitle: const Text(
            'Dial this device at the address above and report what answered.',
          ),
          onTap: controller.testConnection,
        ),
        ListTile(
          key: const Key('device-verify'),
          leading: const Icon(Icons.fingerprint),
          title: Text(
            confirmedAt == null ? 'Check device id' : 'Device id confirmed',
          ),
          subtitle: Text(
            confirmedAt == null
                ? 'Compare the id above with the one this device shows on '
                      'its own This-device page.'
                : 'You confirmed this id on ${formatDate(confirmedAt)}.',
          ),
          onTap: () => _verify(context, device),
        ),
        ListTile(
          key: const Key('device-revoke'),
          leading: Icon(
            Icons.link_off,
            color: Theme.of(context).colorScheme.error,
          ),
          title: const Text('Revoke pairing'),
          subtitle: const Text(
            'Stop trusting this device and refuse its connections.',
          ),
          onTap: () => _revoke(context, device),
        ),
        const Divider(),
        // Last on the page, and the one section that grows without bound.
        // Every other tile here is a single action against the pairing as a
        // whole; this is a list as long as the grants are, and when it sat
        // between them a scroll that overshot a folder's "Stop sharing"
        // landed on "Revoke pairing" — two taps apart, one destroying a
        // grant and the other the pairing. Below everything, an overshoot
        // runs out of page instead, and reaching the pairing-wide actions
        // from here means scrolling back up past the section header.
        _RootsSection(device: device, controller: controller),
      ],
    );
  }

  Future<void> _rename(BuildContext context, PairedDeviceRow device) async {
    final name = await showDialog<String>(
      context: context,
      builder: (context) => _RenameDialog(initialName: device.name),
    );
    if (name != null) await controller.rename(name);
  }

  Future<void> _editAddress(
    BuildContext context,
    PairedDeviceRow device,
  ) async {
    final address = await showDialog<String>(
      context: context,
      builder: (context) => _AddressDialog(initialAddress: device.address),
    );
    if (address != null) await controller.updateAddress(address);
  }

  /// Asks the one question this host cannot answer for itself, and records
  /// whichever answer comes back. Cancelling writes nothing — a user who
  /// opened the dialog to read the id and closed it again has not claimed to
  /// have compared anything.
  Future<void> _verify(BuildContext context, PairedDeviceRow device) async {
    final answer = await showDialog<_VerifyAnswer>(
      context: context,
      builder: (context) => _VerifyDialog(device: device),
    );
    switch (answer) {
      case null:
        return;
      case _VerifyAnswer.match:
        await controller.confirmDeviceId();
      case _VerifyAnswer.mismatch:
        controller.reportDeviceIdMismatch();
      case _VerifyAnswer.clear:
        await controller.clearVerification();
    }
  }

  Future<void> _revoke(BuildContext context, PairedDeviceRow device) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => _RevokeDialog(name: device.name),
    );
    if (confirmed ?? false) await controller.revoke();
  }
}

/// What this host knows the device by: the address it was last reached at,
/// when the pairing happened, the certificate window it is pinned under,
/// and the grouped hex id — last, because it is how the device is addressed
/// rather than how anyone recognises it, and selectable because reading it
/// aloud across a pairing is what it is for.
class _IdentityTile extends StatelessWidget {
  const _IdentityTile(this.device);

  final PairedDeviceRow device;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      children: [
        ListTile(
          title: Text(device.name, style: theme.textTheme.titleLarge),
          subtitle: Text(
            '${device.address}\npaired ${formatDate(device.pairedAt)}',
          ),
        ),
        ListTile(
          leading: const Icon(Icons.verified_user_outlined),
          title: const Text('Pinned certificate'),
          subtitle: Text(
            'issued ${formatDate(device.certificateIssuedAt)} · '
            'expires ${formatDate(device.certificateExpiresAt)}',
          ),
        ),
        ListTile(
          title: const Text('Device id'),
          subtitle: SelectableText(
            device.deviceId,
            key: const Key('device-detail-id'),
            style: theme.textTheme.bodyMedium,
          ),
          // Present only once the user has confirmed the id: an unconfirmed
          // pairing is the ordinary state and says nothing here, so there is
          // no empty slot and no absence to read into.
          trailing: device.verifiedAt == null
              ? null
              : Icon(
                  Icons.verified,
                  key: const Key('device-detail-verified'),
                  color: theme.colorScheme.primary,
                  semanticLabel: 'Device id confirmed',
                ),
        ),
      ],
    );
  }
}

/// The replica roots this host serves to this device (SPEC §4.4's second
/// step), with the two writes that change the set.
///
/// The empty case is a sentence rather than a blank space, because "this
/// device may reach nothing here" is a real and common state — pairing and
/// authorizing are deliberately two steps — and the row above it says
/// nothing about which.
///
/// Each row shows the *elided* label off the device's own row and is keyed
/// and withdrawn by the stored path beside it: the label is for reading,
/// the path is what the write is addressed by, and the two travel together
/// from `PairedDeviceRow.agreedRootLabels` so nothing here computes either.
///
/// Withdrawing asks first, through [WithdrawRootDialog] — the same
/// confirmation the host-level Shared folders page asks, because it is the
/// same write with the same consequence.
class _RootsSection extends StatelessWidget {
  const _RootsSection({required this.device, required this.controller});

  final PairedDeviceRow device;
  final DeviceDetailController controller;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ListTile(
          title: const Text('Folders this device may reach'),
          subtitle: Text(
            'Paths on this device that it is allowed to sync. Pairing and '
            'authorizing are separate: a paired device reaches nothing '
            'until a folder is added here.',
            style: theme.textTheme.bodySmall,
          ),
          trailing: IconButton(
            key: const Key('device-grant-root'),
            icon: const Icon(Icons.add),
            tooltip: 'Share a folder',
            onPressed: () => _grant(context),
          ),
        ),
        if (device.agreedRootLabels.isEmpty)
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Text('No folders shared with this device.'),
          )
        else
          for (final root in device.agreedRootLabels.entries)
            ListTile(
              key: Key('device-root-${root.key}'),
              leading: const Icon(Icons.folder_shared_outlined),
              title: Text(root.value, overflow: TextOverflow.ellipsis),
              trailing: IconButton(
                key: Key('device-withdraw-${root.key}'),
                icon: const Icon(Icons.remove_circle_outline),
                tooltip: 'Stop sharing',
                onPressed: () => _withdraw(context, root.key, root.value),
              ),
            ),
      ],
    );
  }

  Future<void> _grant(BuildContext context) async {
    final path = await showDialog<String>(
      context: context,
      builder: (context) => _GrantDialog(onBrowse: controller.picker.pick),
    );
    if (path != null) await controller.grantRoot(path);
  }

  /// Confirms, then withdraws by the *stored* path — [label] is only what
  /// the dialog names the folder as.
  Future<void> _withdraw(
    BuildContext context,
    String rootPath,
    String label,
  ) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) =>
          WithdrawRootDialog(rootLabel: label, deviceName: device.name),
    );
    if (confirmed ?? false) await controller.revokeRoot(rootPath);
  }
}

/// The folder to share: chosen from the platform folder chooser, or typed
/// when the chooser cannot reach it.
///
/// The chooser leads. Choosing is the answer for almost every grant — the
/// folder exists, the user can see it, and a typed path is a chance to
/// misspell a path nobody will be told was wrong. So it is the first thing
/// in the dialog, it is the filled button, and a folder picked from it pops
/// the dialog straight away: choosing *is* the grant, not a way of filling
/// a field that then has to be confirmed.
///
/// Typing stays, underneath, because the chooser cannot answer every case:
/// a removable card the platform will not hand back a path for, a folder on
/// a desktop this phone is only managing the store for, and — the reason
/// the controller refuses to probe — a root that does not exist yet on the
/// host that will serve it. A grant is authorization, not reachability, so
/// a path the chooser could not show is still a legitimate grant.
///
/// Both land in the same place and are stored through the same expansion,
/// so `~/Sync` chosen here and `~/Sync` typed into `dsync pair grant`
/// record the same string.
class _GrantDialog extends StatefulWidget {
  const _GrantDialog({required this.onBrowse});

  /// Opens the platform chooser and returns what was picked. Taken as a
  /// callback rather than reached for here, so a widget test drives this
  /// dialog without a platform channel.
  final Future<String?> Function() onBrowse;

  @override
  State<_GrantDialog> createState() => _GrantDialogState();
}

class _GrantDialogState extends State<_GrantDialog> {
  final TextEditingController _path = TextEditingController();

  @override
  void dispose() {
    _path.dispose();
    super.dispose();
  }

  /// Opens the chooser and, if a folder came back, grants it — the dialog
  /// closes on the choice rather than asking the user to confirm what they
  /// just picked.
  Future<void> _browse() async {
    final navigator = Navigator.of(context);
    final String? picked;
    try {
      picked = await widget.onBrowse();
    } catch (_) {
      // A chooser that will not open is reported by the controller when a
      // grant is actually attempted; here it only means the dialog stays
      // open on the typed field, which is the fallback for exactly this.
      return;
    }
    if (picked != null) navigator.pop(picked);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AlertDialog(
      title: const Text('Share a folder'),
      content: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          FilledButton.icon(
            key: const Key('device-grant-browse'),
            onPressed: _browse,
            icon: const Icon(Icons.folder_open),
            label: const Text('Choose folder'),
          ),
          const SizedBox(height: 16),
          Text(
            'Or type a path — a folder that is not on this device, or does '
            'not exist here yet, can still be authorized.',
            style: theme.textTheme.bodySmall,
          ),
          TextField(
            key: const Key('device-grant-path-field'),
            controller: _path,
            decoration: const InputDecoration(
              labelText: 'Folder on this device',
              hintText: '~/Sync',
            ),
            onSubmitted: (value) => Navigator.of(context).pop(value),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const Key('device-grant-confirm'),
          onPressed: () => Navigator.of(context).pop(_path.text),
          child: const Text('Share'),
        ),
      ],
    );
  }
}

/// The new local label. Pops the typed name, or nothing when cancelled; the
/// empty-name and already-taken refusals are the controller's and the
/// store's, so there is one rule about each rather than two.
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
      title: const Text('Rename device'),
      content: TextField(
        key: const Key('device-name-field'),
        controller: _name,
        autofocus: true,
        decoration: const InputDecoration(labelText: 'Name'),
        onSubmitted: (value) => Navigator.of(context).pop(value),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const Key('device-rename-confirm'),
          onPressed: () => Navigator.of(context).pop(_name.text),
          child: const Text('Rename'),
        ),
      ],
    );
  }
}

/// Where to reach the device: `host`, or `host:port` when it listens
/// somewhere other than the default. Pops the typed text, or nothing when
/// cancelled — what counts as an address is the core's, decided when the
/// controller hands it over, so this dialog holds no rule of its own and a bad address comes back as the page's own error
/// line rather than as two disagreeing validations.
///
/// Pre-filled with what is on file, because correcting an address is
/// usually changing one octet of it.
class _AddressDialog extends StatefulWidget {
  const _AddressDialog({required this.initialAddress});

  final String initialAddress;

  @override
  State<_AddressDialog> createState() => _AddressDialogState();
}

class _AddressDialogState extends State<_AddressDialog> {
  late final TextEditingController _address = TextEditingController(
    text: widget.initialAddress,
  );

  @override
  void dispose() {
    _address.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Address'),
      content: TextField(
        key: const Key('device-address-field'),
        controller: _address,
        autofocus: true,
        decoration: const InputDecoration(
          labelText: 'Address',
          hintText: '10.0.0.7:28771',
        ),
        onSubmitted: (value) => Navigator.of(context).pop(value),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const Key('device-address-confirm'),
          onPressed: () => Navigator.of(context).pop(_address.text),
          child: const Text('Save'),
        ),
      ],
    );
  }
}

/// What the user said when they compared the two screens — or that they
/// took an earlier answer back.
///
/// Three cases rather than a `bool?`, because "they differ" is not the
/// absence of "they match": one is a pairing to throw away and the other is
/// a dialog the user closed, and the page does something different with
/// each.
enum _VerifyAnswer { match, mismatch, clear }

/// The id this host pinned, beside the question only the user can answer:
/// is this what the other device shows?
///
/// **It asks, rather than offering a "Verify" button to press.** A button
/// that turns a pairing green because it was tapped teaches the user that
/// green means "I tapped it", and the one prompt that should ever stop them
/// becomes the one they click through fastest. So the dialog leads with the
/// id, names where to find its counterpart, and offers both answers —
/// "they differ" being a real outcome with a real consequence, not a
/// cancel.
///
/// **And it says what verifying is not for.** Pairing already pins this
/// device's key; nothing here is what makes a connection safe, and a user
/// who never opens this dialog is not doing anything wrong. Saying so is
/// what keeps this an optional tool rather than a chore with a badge
/// attached.
class _VerifyDialog extends StatelessWidget {
  const _VerifyDialog({required this.device});

  final PairedDeviceRow device;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final confirmedAt = device.verifiedAt;
    return AlertDialog(
      title: const Text('Check device id'),
      content: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            'Open ${device.name} and read the id on its This-device page. '
            'It should be exactly this:',
          ),
          const SizedBox(height: 12),
          SelectableText(
            device.deviceId,
            key: const Key('device-verify-id'),
            style: theme.textTheme.bodyMedium,
          ),
          const SizedBox(height: 12),
          Text(
            'This is optional. Pairing already pins this device\'s key — '
            'comparing the two screens is how you tell that the key pinned '
            'here is the one that device actually holds.',
            style: theme.textTheme.bodySmall,
          ),
          if (confirmedAt != null) ...[
            const SizedBox(height: 12),
            Text(
              'Confirmed on ${formatDate(confirmedAt)}.',
              style: theme.textTheme.bodySmall,
            ),
          ],
        ],
      ),
      actions: [
        if (confirmedAt != null)
          TextButton(
            key: const Key('device-verify-clear'),
            onPressed: () => Navigator.of(context).pop(_VerifyAnswer.clear),
            child: const Text('Clear'),
          ),
        TextButton(
          key: const Key('device-verify-differ'),
          onPressed: () => Navigator.of(context).pop(_VerifyAnswer.mismatch),
          style: TextButton.styleFrom(foregroundColor: theme.colorScheme.error),
          child: const Text('They differ'),
        ),
        FilledButton(
          key: const Key('device-verify-match'),
          onPressed: () => Navigator.of(context).pop(_VerifyAnswer.match),
          child: const Text('They match'),
        ),
      ],
    );
  }
}

/// The confirmation before a revoke. Its text carries SPEC §4.4's
/// one-sidedness in the user's words: revoking here only makes this device
/// forget the peer; the peer keeps its own entry and is told nothing.
class _RevokeDialog extends StatelessWidget {
  const _RevokeDialog({required this.name});

  final String name;

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text('Revoke $name?'),
      content: Text(
        'This device will stop trusting $name and will refuse its '
        'connections.\n\n'
        'This only changes this device. $name is not told and still trusts '
        'this device until you revoke there too.',
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

/// What is left once the device is no longer paired.
class _Gone extends StatelessWidget {
  const _Gone({required this.onGone});

  final VoidCallback onGone;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('This device is no longer paired.'),
            const SizedBox(height: 16),
            FilledButton(
              key: const Key('device-detail-back'),
              onPressed: onGone,
              child: const Text('Back to devices'),
            ),
          ],
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
