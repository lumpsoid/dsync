import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'pair_code.dart';
import 'pair_controller.dart';
import 'pair_scope.dart';
import 'pair_view_state.dart';
import 'scan_code_page.dart';

/// The Pair page: enrol against a `dsync-pair:1.0:` payload (SPEC §4.4).
/// Widgets only, per the page role in `app_scope.dart`: two ways to get a
/// code, a card describing the one that was read, two name fields, one
/// button, and a switch over the rendered [PairOutcome].
///
/// **The page is two steps, and the first one commits to nothing.** A
/// payload arrives either way the user likes — the QR read by the camera on
/// [ScanCodePage], or the line `dsync pair show` prints beside it, pasted
/// from the clipboard — and both land in `PairController.codeEntered`,
/// which decodes it and says what it is. Only then does the rest of the page
/// appear: the device the code names, the address it says to reach it at,
/// and the two names, with a button that is the only thing here that sends
/// anything. A scan that arrives is something to look at, not a decision
/// that has already been taken on the user's behalf.
///
/// The base64 line itself is never shown. It cannot be checked by reading
/// it, and the card above the names says the two things about it a person
/// can actually check — which device, and where.
///
/// **The one name here is not something the user has to invent.** The field
/// arrives filled in with the desktop's own name, as the core reads it out
/// of the payload it printed, so the page can be completed by scanning one
/// code and pressing one button. It stays an ordinary editable field:
/// what is offered is overwritten by whatever the user types, and a field
/// emptied says so at the keyboard rather than after a tap that did nothing
/// (`PairController.localNameEdited`).
///
/// **There is no field for what the desktop calls this device.** That name
/// is the desktop's own choice, made where it showed the payload
/// (`dsync pair show --name`) — see `EnrolmentRequest`'s doc comment for why
/// an enrolling device no longer proposes one.
///
/// **The submit puts this device's own id on screen.** The moment the token
/// is redeemed, the desktop shows the id it was presented and asks whoever
/// is standing there whether that is the device they meant
/// (`pair_show_page.dart`). That question has two halves and they are on two
/// screens: without the id here, the person holding the phone has nothing to
/// compare it against short of leaving the pairing flow for `This device`.
/// `dsync pair accept` prints its own id at the same point, for the same
/// reason.
///
/// **The camera is mounted by the tap, and on a route of its own.** Starting
/// `MobileScanner` is what asks the OS for the camera, so a page that built
/// it unconditionally would put a permission prompt in front of someone who
/// came to paste a line. Every way the camera can fail — denied, no camera,
/// no plugin for this platform — lands as a line on that page saying so,
/// with this one, and its Paste button, still underneath. Nothing here is
/// ever blocked on the camera.
///
/// **The other end of the same exchange is one tap away.** `Show this
/// device's code` leads to the page that binds an endpoint here and offers
/// this device's own payload (`features/pair_show/`), for the pairing where
/// the camera is on the *other* device. It sits under the two ways in rather
/// than beside them: reading someone else's code is what this page is for,
/// and showing one is the other way round.
///
/// [onPaired] is the seam back to Devices: the controller has refreshed
/// `AppState.devices` by the time it fires, so the destination needs
/// nothing handed to it. The entrypoint wires it to a pop; this page holds
/// no `Navigator` of its own other than the scan route it pushes and the
/// scan route pops — and the confirmation naming the device it paired with
/// is shown just before, through the app's `ScaffoldMessenger`, so it is
/// still on screen once Devices is.
class PairPage extends StatefulWidget {
  const PairPage({
    super.key,
    required this.onPaired,
    required this.onShowOwnCode,
    required this.scanner,
  });

  /// Called once after a successful pairing, when the page should leave.
  final VoidCallback onPaired;

  /// Opens the page that shows this device's own pairing code, for the
  /// pairing that goes the other way round.
  final VoidCallback onShowOwnCode;

  /// The camera, handed on to [ScanCodePage] when the user asks for it —
  /// named at the route the way the scope names the real `enrolWithPeer`,
  /// so the real one is what a production build gets and a fake cannot
  /// arrive by omission.
  final PairScanner scanner;

  @override
  State<PairPage> createState() => _PairPageState();
}

class _PairPageState extends State<PairPage> {
  final _localName = TextEditingController();

  /// The desktop name this page last put in the field itself, so it can tell
  /// its own offer from a name the user typed — and never overwrite the
  /// second. One string rather than a `bool edited` beside the text: the
  /// question is only ever "is the field still showing what I put there",
  /// and a flag kept in step with the text is one more thing that can drift.
  String? _offeredDesktopName;

  @override
  void initState() {
    super.initState();
    // The controller is the cached one and outlives this page, so the page
    // says where it starts rather than inheriting the last visit's verdict.
    //
    // The listener is attached after that: an untouched field is not an
    // edited one, and it is editing a name away that earns the line under
    // it.
    pairScope.controller.beginPairing();
    _localName.addListener(_localNameEdited);
  }

  void _localNameEdited() =>
      pairScope.controller.localNameEdited(_localName.text);

  /// A text that should be a payload, however it was got: the controller
  /// decides what it is, and the desktop names itself inside it, so the
  /// field for that name fills itself in as soon as one is readable. Left
  /// alone once the user has put something else there.
  Future<void> _codeEntered(String text) async {
    final controller = pairScope.controller;
    await controller.codeEntered(text);
    if (!mounted) return;
    if (controller.state.code case PairCodeRead(:final desktopName)) {
      if (_localName.text != (_offeredDesktopName ?? '')) return;
      _offeredDesktopName = desktopName;
      _localName.text = desktopName;
    }
  }

  /// The camera, on a page of its own, which closes on the first code it
  /// reads and hands its text back. Nothing is sent: what comes back fills
  /// this page in, and the user still presses the button.
  Future<void> _scan() async {
    final raw = await Navigator.of(context).push<String>(
      MaterialPageRoute(
        builder: (_) => ScanCodePage(scanner: widget.scanner),
        fullscreenDialog: true,
      ),
    );
    if (raw == null || !mounted) return;
    await _codeEntered(raw);
  }

  /// The clipboard, as the second way in: the `dsync-pair:1.0:` line reaches
  /// a phone by being copied out of something else, and a long press on a
  /// text field is an affordance only to someone who already knows it is
  /// there.
  ///
  /// The text is trimmed because a line copied out of a terminal carries the
  /// newline that ended it.
  Future<void> _paste() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text?.trim();
    if (text == null || text.isEmpty || !mounted) return;
    await _codeEntered(text);
  }

  @override
  void dispose() {
    _localName.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final controller = pairScope.controller;
    await controller.submitPayload(localName: _localName.text);
    _leaveIfPaired(controller);
  }

  /// Leaves on success, having said so first.
  ///
  /// The confirmation goes through `ScaffoldMessenger`, and the one it
  /// finds is the app's — `MaterialApp` installs it above the `Navigator`,
  /// so the snackbar outlives this page's pop and is read on Devices, over
  /// the row that has just appeared. Without it a successful pairing says
  /// nothing at all: this page renders nothing for [PairSucceeded] because
  /// it is leaving, and the user is left to infer that it worked from a
  /// list they were not looking at.
  ///
  /// Raised here rather than on Devices because the desktop's name is this
  /// exchange's own result — Devices is never told a pairing happened, and
  /// its only other way to name the device would be to hunt the refreshed
  /// list for whichever row is new.
  void _leaveIfPaired(PairController controller) {
    if (!mounted) return;
    if (controller.state.outcome case PairSucceeded(:final deviceName)) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Paired with $deviceName.')));
      widget.onPaired();
    }
  }

  @override
  Widget build(BuildContext context) {
    final controller = pairScope.controller;
    return Scaffold(
      appBar: AppBar(title: const Text('Pair a device')),
      body: ListenableBuilder(
        listenable: controller.state,
        builder: (context, _) => _PairForm(
          state: controller.state,
          onScan: _scan,
          onPaste: _paste,
          onShowOwnCode: widget.onShowOwnCode,
          onClearCode: controller.clearCode,
          localName: _localName,
          onSubmit: _submit,
        ),
      ),
    );
  }
}

class _PairForm extends StatelessWidget {
  const _PairForm({
    required this.state,
    required this.onScan,
    required this.onPaste,
    required this.onShowOwnCode,
    required this.onClearCode,
    required this.localName,
    required this.onSubmit,
  });

  final PairViewState state;

  final VoidCallback onScan;
  final VoidCallback onPaste;
  final VoidCallback onShowOwnCode;
  final VoidCallback onClearCode;
  final TextEditingController localName;
  final VoidCallback onSubmit;

  @override
  Widget build(BuildContext context) {
    final submitting = state.outcome is PairSubmitting;
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        const Text(
          'On the desktop, run `dsync pair show`. Scan the QR code it '
          'prints, or paste the `dsync-pair:1.0:` line beside it.',
        ),
        const SizedBox(height: 16),
        switch (state.code) {
          PairCodeMissing() => _CodeActions(
            onScan: onScan,
            onPaste: onPaste,
            enabled: !submitting,
          ),
          PairCodeUnreadable(:final message) => _UnreadableCode(
            message: message,
            onScan: onScan,
            onPaste: onPaste,
            enabled: !submitting,
          ),
          PairCodeRead(:final desktopName, :final address) => _CodeCard(
            desktopName: desktopName,
            address: address,
            onClear: submitting ? null : onClearCode,
          ),
        },
        // The way round this page is not for, offered only while it is
        // still open which way round this pairing goes: once a code has been
        // read, showing one instead would throw it away.
        if (state.code is! PairCodeRead) ...[
          const SizedBox(height: 24),
          const Divider(),
          const SizedBox(height: 8),
          const Text(
            'No code to hand? Let the other device scan this one instead.',
          ),
          const SizedBox(height: 12),
          OutlinedButton.icon(
            key: const Key('pair-show-own-code'),
            onPressed: onShowOwnCode,
            icon: const Icon(Icons.qr_code_2),
            label: const Text("Show this device's code"),
          ),
        ],
        // The name and the button belong to a code: there is nothing to
        // name, and nothing to send, until one has been read.
        if (state.code is PairCodeRead) ...[
          const SizedBox(height: 24),
          TextField(
            key: const Key('pair-local-name'),
            controller: localName,
            enabled: !submitting,
            decoration: InputDecoration(
              labelText: 'Name for the desktop',
              helperText:
                  'What this device will show it as. What the desktop '
                  'calls this device is its own choice, made there.',
              errorText: state.localNameError,
            ),
          ),
          // The other half of the confirmation the desktop is putting in
          // front of whoever is standing there. It appears with the submit,
          // because that is when the desktop asks.
          if (state.ownDeviceId case final ownDeviceId?) ...[
            const SizedBox(height: 24),
            _OwnIdCard(ownDeviceId),
          ],
          const SizedBox(height: 24),
          _OutcomeLine(state.outcome),
          // No spinner while submitting: almost all of that wait is the
          // operator confirming on the other device, so the button says where
          // the next step is instead of animating over it.
          FilledButton(
            key: const Key('pair-submit'),
            onPressed: submitting ? null : onSubmit,
            child: Text(submitting ? 'Confirm on the other device' : 'Pair'),
          ),
        ],
      ],
    );
  }
}

/// The two ways to get a code, side by side and weighted: the camera is the
/// one the desktop's own output points at, and pasting is for the user who
/// already has the line somewhere.
class _CodeActions extends StatelessWidget {
  const _CodeActions({
    required this.onScan,
    required this.onPaste,
    required this.enabled,
  });

  final VoidCallback onScan;
  final VoidCallback onPaste;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: FilledButton.tonalIcon(
            key: const Key('pair-scan'),
            onPressed: enabled ? onScan : null,
            icon: const Icon(Icons.qr_code_scanner),
            label: const Text('Scan QR code'),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: OutlinedButton.icon(
            key: const Key('pair-paste'),
            onPressed: enabled ? onPaste : null,
            icon: const Icon(Icons.content_paste),
            label: const Text('Paste line'),
          ),
        ),
      ],
    );
  }
}

/// A text that was read but is not a payload this build can use — the wrong
/// QR code, a half-copied line. Says what it was and leaves both ways in
/// right underneath, because the fix is always to fetch another one.
class _UnreadableCode extends StatelessWidget {
  const _UnreadableCode({
    required this.message,
    required this.onScan,
    required this.onPaste,
    required this.enabled,
  });

  final String message;
  final VoidCallback onScan;
  final VoidCallback onPaste;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(Icons.error_outline, color: colors.error),
            const SizedBox(width: 12),
            Expanded(
              child: Text(message, style: TextStyle(color: colors.error)),
            ),
          ],
        ),
        const SizedBox(height: 16),
        _CodeActions(onScan: onScan, onPaste: onPaste, enabled: enabled),
      ],
    );
  }
}

/// What the code turned out to say: the device about to be paired with, and
/// where it is answering. The whole point of the redesign — this is on
/// screen, with the names under it, before anything is sent.
class _CodeCard extends StatelessWidget {
  const _CodeCard({
    required this.desktopName,
    required this.address,
    required this.onClear,
  });

  final String desktopName;
  final String address;

  /// `null` while the exchange is in flight: swapping the code out from
  /// under a submit is the one thing this button must not do.
  final VoidCallback? onClear;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      key: const Key('pair-code-card'),
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  Icons.check_circle_outline,
                  color: theme.colorScheme.primary,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(desktopName, style: theme.textTheme.titleMedium),
                      Text(
                        address,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton(
                key: const Key('pair-clear-code'),
                onPressed: onClear,
                child: const Text('Use a different code'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// This device's own id, for the question being asked on the other screen
/// (task 23344d, SPEC §4.4): the desktop shows the id it was presented and
/// asks whoever is there whether it is the right device. Without this the
/// person holding the phone has nothing to read out, and the comparison the
/// whole confirmation rests on cannot be made without leaving the pairing
/// flow for `This device`.
///
/// Rendered the way the desktop renders the id it is asking about
/// (`pair_show_page.dart`): grouped hex, monospaced, selectable, and wrapped
/// rather than truncated — a comparison that cannot see every group is not a
/// comparison.
class _OwnIdCard extends StatelessWidget {
  const _OwnIdCard(this.deviceId);

  final String deviceId;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'The desktop is asking whoever is there to confirm the id it was '
          'presented, before it records the pairing. This device is:',
        ),
        const SizedBox(height: 12),
        Card(
          key: const Key('pair-own-device-id-card'),
          margin: EdgeInsets.zero,
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: SelectableText(
              deviceId,
              key: const Key('pair-own-device-id'),
              style: theme.textTheme.bodyMedium?.copyWith(
                fontFamily: 'monospace',
              ),
            ),
          ),
        ),
        const SizedBox(height: 12),
        Text(
          'Read it out group by group. If every group matches what the '
          'desktop shows, it is this device that redeemed the code.',
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ],
    );
  }
}

/// The line above the button for the outcome that has one. Success shows
/// nothing here: the page is leaving, and it confirms itself on the way out
/// with a snackbar that outlives the pop (`_PairPageState._leaveIfPaired`).
class _OutcomeLine extends StatelessWidget {
  const _OutcomeLine(this.outcome);

  final PairOutcome outcome;

  @override
  Widget build(BuildContext context) {
    return switch (outcome) {
      PairFailed(:final message) => Padding(
        padding: const EdgeInsets.only(bottom: 16),
        child: Text(
          message,
          style: TextStyle(color: Theme.of(context).colorScheme.error),
        ),
      ),
      PairSubmitting() => const Padding(
        padding: EdgeInsets.only(bottom: 16),
        child: Text(
          'Now go to the other device: it shows an id and asks whether it is '
          "this device's. This page finishes by itself once it is confirmed "
          'there.',
        ),
      ),
      PairIdle() || PairSucceeded() => const SizedBox.shrink(),
    };
  }
}
