import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'pair_show_controller.dart';
import 'pair_show_scope.dart';
import 'pair_show_view_state.dart';
import 'pairing_offer.dart';
import 'qr_symbol.dart';

/// The Show-this-device's-code page: `dsync pair show` with a screen
/// (SPEC §4.4). Widgets only, per the page role in `app_scope.dart`: it
/// switches over [PairShowStatus] and renders the offer the controller
/// built.
///
/// **Owns its controller.** It takes `pairShowScope.create()` — never the
/// cached `controller` most pages read — and disposes it in
/// [State.dispose], the way `RunPage` does and for a sharper version of the
/// same reason: the controller holds a bound enrolment endpoint, and SPEC
/// §4.4's "open only for the duration of one pairing operation" is exactly
/// this page's lifetime. Leaving closes it.
///
/// **One field, then the code.** The page asks what to call the device
/// about to be paired and shows the code once it has an answer. That name
/// is this device's own handle for its peer — what the device list, a
/// grant and a `peer://` location address it by — and it has to be decided
/// *before* the endpoint is bound, because whoever redeems the code is
/// recorded under it the instant they do; letting the enrolling device
/// propose it instead is what `EnrolmentRequest`'s doc comment describes
/// closing. Every ending that can be retried comes back to the same field,
/// because a spent or expired token can never be reopened and because a
/// refusal naming a name collision is fixed by typing a different one.
///
/// **Both ways out of the payload, side by side.** The symbol is for the
/// other device's camera (its own Pair page), the line under it for its
/// clipboard or its terminal (`dsync pair accept <line>`) — the same pair
/// the CLI prints, for the same reason: which one is usable depends on which
/// devices are in the room, and neither replaces the other.
///
/// **One question before anything is recorded.** A device that redeems the
/// code does not get stored on the strength of that alone (task 23344d):
/// the page shows the id it presented and asks the operator to compare it
/// against the id that device shows itself. Refusing records nothing, and
/// comes back to the same retry the other endings do, because the code is
/// spent either way.
///
/// [onPaired] is the seam back to Devices: `AppState.devices` already holds
/// the new row by the time it fires, so the destination needs nothing handed
/// to it. The confirmation naming the device goes through the app's
/// `ScaffoldMessenger`, so it outlives this page's pop — the same shape
/// `PairPage` uses from the other end of the exchange.
class PairShowPage extends StatefulWidget {
  const PairShowPage({super.key, required this.onPaired});

  /// Called once after a device has enrolled, when the page should leave.
  final VoidCallback onPaired;

  @override
  State<PairShowPage> createState() => _PairShowPageState();
}

class _PairShowPageState extends State<PairShowPage> {
  final PairShowController _controller = pairShowScope.create();

  /// What this device will call whoever redeems the code. Kept across a
  /// retry, so a window that expired is re-shown with one tap and one that
  /// was refused for a name collision is re-shown after an edit.
  final TextEditingController _name = TextEditingController();

  /// Whether a window has been opened for the name now in [_name]. False
  /// until the first Show-code, and again after an ending that offers a
  /// retry.
  bool _showing = false;

  /// Whether [PairShowPage.onPaired] has already fired. The status is
  /// written from an async wait, so a rebuild for any other reason must not
  /// pop the page a second time.
  bool _left = false;

  @override
  void initState() {
    super.initState();
    _controller.state.addListener(_statusChanged);
  }

  @override
  void dispose() {
    _controller.state.removeListener(_statusChanged);
    _name.dispose();
    // Closes the endpoint: see the class doc comment.
    _controller.dispose();
    super.dispose();
  }

  void _statusChanged() {
    if (_left || !mounted) return;
    if (_controller.state.status case PairShowPaired(:final deviceName)) {
      _left = true;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Paired with $deviceName.')));
      widget.onPaired();
    }
  }

  void _show() {
    setState(() => _showing = true);
    unawaited(_controller.show(peerName: _name.text.trim()));
  }

  /// Back to the field, rather than straight into a fresh window: the name
  /// is the one thing worth changing between attempts (a refusal that named
  /// a collision is fixed nowhere else), and it is already filled in.
  Future<void> _showAnother() async {
    await _controller.stop();
    if (mounted) setState(() => _showing = false);
  }

  Future<void> _copy(String line) async {
    await Clipboard.setData(ClipboardData(text: line));
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(const SnackBar(content: Text('Pairing code copied.')));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text("This device's code")),
      body: !_showing
          ? _NameField(name: _name, onShow: _show)
          : ListenableBuilder(
              listenable: _controller.state,
              builder: (context, _) => switch (_controller.state.status) {
                PairShowStarting() => const Center(
                  child: CircularProgressIndicator(
                    semanticsLabel: 'Opening a pairing window',
                  ),
                ),
                PairShowWaiting(:final offer) => _Offer(
                  offer: offer,
                  onCopy: () => _copy(offer.payloadLine),
                ),
                PairShowConfirming(:final deviceId, :final peerName) =>
                  _Confirm(
                    deviceId: deviceId,
                    peerName: peerName,
                    onAnswer: (confirmed) =>
                        _controller.answerConfirmation(confirmed: confirmed),
                  ),
                PairShowDeclined() => _Ended(
                  key: const Key('pair-show-declined'),
                  message:
                      'You turned that device away, so nothing was recorded. '
                      'The code is used up either way — show a new one when '
                      'the device you meant is ready.',
                  isError: false,
                  onRetry: () => unawaited(_showAnother()),
                ),
                // Rendered as the window it is: the page is leaving, and says so
                // through the snackbar `_statusChanged` raises.
                PairShowPaired() => const SizedBox.shrink(),
                PairShowExpired(:final window) => _Ended(
                  key: const Key('pair-show-expired'),
                  message:
                      'Nothing used this code before it ran out. Codes are good '
                      'for ${window.inMinutes} minutes, so the '
                      'other device needs to be ready before you show one.',
                  isError: false,
                  onRetry: () => unawaited(_showAnother()),
                ),
                PairShowFailed(:final message) => _Ended(
                  key: const Key('pair-show-failed'),
                  message: message,
                  isError: true,
                  onRetry: () => unawaited(_showAnother()),
                ),
              },
            ),
    );
  }
}

/// The one question this side has to answer before a code exists: what to
/// call the device that redeems it.
///
/// No default is offered. The name is a handle the operator will type again
/// — in a grant, in a `peer://` location — and a guessed one ("device",
/// this device's own model) would be both wrong and hard to notice; the
/// Pair page's two name fields are filled in by hand for the same reason.
class _NameField extends StatelessWidget {
  const _NameField({required this.name, required this.onShow});

  final TextEditingController name;
  final VoidCallback onShow;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: name,
      builder: (context, _) {
        final ready = name.text.trim().isNotEmpty;
        return ListView(
          padding: const EdgeInsets.all(16),
          children: [
            const Text(
              'What should this device call the one you are about to pair? '
              'The name is local to this device, and it is how you will '
              'pick that device out of the list later.',
            ),
            const SizedBox(height: 16),
            TextField(
              key: const Key('pair-show-name'),
              controller: name,
              autofocus: true,
              textInputAction: TextInputAction.done,
              onSubmitted: (_) {
                if (ready) onShow();
              },
              decoration: const InputDecoration(
                labelText: 'Name for the other device',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 24),
            FilledButton(
              key: const Key('pair-show-start'),
              onPressed: ready ? onShow : null,
              child: const Text('Show code'),
            ),
          ],
        );
      },
    );
  }
}

/// The open window: what to do with the code, the code itself both ways, and
/// the fact that nothing has taken it yet.
class _Offer extends StatelessWidget {
  const _Offer({required this.offer, required this.onCopy});

  final PairingOffer offer;
  final VoidCallback onCopy;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final symbol = offer.symbol;
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        const Text(
          'On the other device, open Pair a device and scan this code — or '
          'copy the line below and run `dsync pair accept <line>` there.',
        ),
        const SizedBox(height: 16),
        if (symbol != null)
          Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 280),
              child: Card(
                key: const Key('pair-show-symbol'),
                clipBehavior: Clip.antiAlias,
                margin: EdgeInsets.zero,
                child: QrSymbol(symbol),
              ),
            ),
          )
        else
          Text(
            'This code is too large to show as a QR symbol — use the line '
            'below instead.',
            style: TextStyle(color: theme.colorScheme.error),
          ),
        const SizedBox(height: 16),
        Card(
          margin: EdgeInsets.zero,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SelectableText(
                  offer.payloadLine,
                  key: const Key('pair-show-line'),
                  maxLines: 3,
                  style: theme.textTheme.bodySmall?.copyWith(
                    fontFamily: 'monospace',
                  ),
                ),
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton.icon(
                    key: const Key('pair-show-copy'),
                    onPressed: onCopy,
                    icon: const Icon(Icons.content_copy),
                    label: const Text('Copy line'),
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 24),
        // Still, not a spinner: the wait is the operator walking to the
        // other device, which no animation here can speed up or report on.
        // What they can use is the deadline, and the page changes by itself
        // the moment a device uses the code.
        Row(
          children: [
            const Icon(Icons.schedule, size: 20),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                'Waiting for a device to use this code. It stops working at '
                '${_clockTime(offer.expiresAt)}.',
              ),
            ),
          ],
        ),
        const SizedBox(height: 16),
        Text(
          'This device is answering at ${offer.address}. Both devices have '
          'to be on the same network.',
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ],
    );
  }
}

/// The question that decides the pairing (task 23344d, SPEC §4.4): the id
/// of whatever redeemed the code, against the id that device shows on its
/// own screen.
///
/// Both answers are buttons of equal weight, and neither is pre-selected.
/// The id is the whole content — grouped hex, monospaced, wrapped rather
/// than truncated, because a comparison that cannot see every group is not
/// a comparison. Nothing has been recorded at the moment this is on screen;
/// refusing records nothing at all.
class _Confirm extends StatelessWidget {
  const _Confirm({
    required this.deviceId,
    required this.peerName,
    required this.onAnswer,
  });

  final String deviceId;
  final String peerName;
  final void Function(bool confirmed) onAnswer;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        const Text(
          'A device used the code. Before it is paired, check that it is '
          'the one you meant: this is the id it presented.',
        ),
        const SizedBox(height: 16),
        Card(
          margin: EdgeInsets.zero,
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: SelectableText(
              deviceId,
              key: const Key('pair-show-device-id'),
              style: theme.textTheme.bodyMedium?.copyWith(
                fontFamily: 'monospace',
              ),
            ),
          ),
        ),
        const SizedBox(height: 16),
        Text(
          'That device shows the same id on its own screen. Pair only if '
          'every group matches — if it does not, somebody else got to the '
          'code first. Paired, it will be listed here as "$peerName".',
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 24),
        Row(
          children: [
            Expanded(
              child: OutlinedButton(
                key: const Key('pair-show-refuse'),
                onPressed: () => onAnswer(false),
                child: const Text('Not my device'),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: FilledButton(
                key: const Key('pair-show-confirm'),
                onPressed: () => onAnswer(true),
                child: const Text('Ids match — pair'),
              ),
            ),
          ],
        ),
      ],
    );
  }
}

/// A window that ended without a pairing — run out, or never opened. Says
/// which, and offers a fresh one, because a token can never be reopened.
class _Ended extends StatelessWidget {
  const _Ended({
    super.key,
    required this.message,
    required this.isError,
    required this.onRetry,
  });

  final String message;
  final bool isError;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(
              isError ? Icons.error_outline : Icons.timer_off_outlined,
              color: isError ? theme.colorScheme.error : null,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                message,
                style: isError
                    ? TextStyle(color: theme.colorScheme.error)
                    : null,
              ),
            ),
          ],
        ),
        const SizedBox(height: 24),
        FilledButton(
          key: const Key('pair-show-retry'),
          onPressed: onRetry,
          child: const Text('Show a new code'),
        ),
      ],
    );
  }
}

/// A local wall-clock time as `HH:MM`, for the one line that names when the
/// code stops working.
///
/// The widget layer's job for the reason `formatDate` gives — and kept to
/// the minute here because that is the whole point of the line. Not
/// localised; task fc8e49 is where every string in the head is.
String _clockTime(DateTime at) {
  final local = at.toLocal();
  return '${local.hour.toString().padLeft(2, '0')}:'
      '${local.minute.toString().padLeft(2, '0')}';
}
