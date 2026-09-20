import 'dart:async';

import 'package:dsync/dsync_core/identity/enrolment_listener.dart';
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
/// **The window opens by arriving.** There is no start button: getting here
/// is the intent, the code is useless for five minutes at a time, and a
/// button to make a code appear would only add a tap between the user and
/// the thing they came for. Every ending that can be retried offers a fresh
/// window instead, because a spent or expired token can never be reopened.
///
/// **Both ways out of the payload, side by side.** The symbol is for the
/// other device's camera (its own Pair page), the line under it for its
/// clipboard or its terminal (`dsync pair accept <line>`) — the same pair
/// the CLI prints, for the same reason: which one is usable depends on which
/// devices are in the room, and neither replaces the other.
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

  /// Whether [PairShowPage.onPaired] has already fired. The status is
  /// written from an async wait, so a rebuild for any other reason must not
  /// pop the page a second time.
  bool _left = false;

  @override
  void initState() {
    super.initState();
    _controller.state.addListener(_statusChanged);
    unawaited(_controller.show());
  }

  @override
  void dispose() {
    _controller.state.removeListener(_statusChanged);
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
      body: ListenableBuilder(
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
          // Rendered as the window it is: the page is leaving, and says so
          // through the snackbar `_statusChanged` raises.
          PairShowPaired() => const SizedBox.shrink(),
          PairShowExpired() => _Ended(
            key: const Key('pair-show-expired'),
            message:
                'Nothing used this code before it ran out. Codes are good '
                'for ${defaultEnrolmentTokenTtl.inMinutes} minutes, so the '
                'other device needs to be ready before you show one.',
            isError: false,
            onRetry: () => unawaited(_controller.show()),
          ),
          PairShowFailed(:final message) => _Ended(
            key: const Key('pair-show-failed'),
            message: message,
            isError: true,
            onRetry: () => unawaited(_controller.show()),
          ),
        },
      ),
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
        Row(
          children: [
            const SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                semanticsLabel: 'Waiting for the other device',
              ),
            ),
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
