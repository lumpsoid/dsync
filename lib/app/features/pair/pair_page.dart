import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import 'default_names.dart';
import 'pair_controller.dart';
import 'pair_scope.dart';
import 'pair_view_state.dart';

/// The camera, as the Pair page's second input method (SPEC §4.4):
/// built by the route that opens the page (`dsync_app.dart`, from the real
/// `mobile_scanner` widget below) and by a test from whatever stands in for
/// one — a widget test host has no camera and no plugin behind it, so a page
/// that built the real one would be testing the plugin's channel rather than
/// this page.
///
/// The page hands [onScanned] over and says nothing else about what comes
/// back: whether that is a preview, a permission prompt, or a line saying
/// this build has no camera is the builder's business. What it must not do
/// is decide anything about what it read.
typedef PairScanner = Widget Function(ValueChanged<String> onScanned);

/// The Pair page: enrol against a `dsync-pair:v1:` payload (SPEC §4.4).
/// Widgets only, per the page role in `app_scope.dart`: a camera, three text
/// fields, one button, and a switch over the rendered [PairOutcome].
///
/// The payload arrives two ways — the line `dsync pair show` prints beside
/// its QR, typed or pasted in, and the QR itself, read by the camera — and
/// both leave through `PairController`: the pasted text through
/// `submitPayload`, the scanned text through `onPayloadScanned`, which is
/// that same path with the guard a source that fires repeatedly needs. Which
/// of the two a user uses is the whole of their choice; nothing else on this
/// page knows which one produced the payload it is showing.
///
/// **Neither name is something the user has to invent.** The two name
/// fields arrive filled in from what is already known — this device's own
/// host name, and the desktop's, read out of the certificate inside the
/// payload it printed (`default_names.dart`) — so the page can be completed
/// by pasting one line and pressing one button. Both stay ordinary editable
/// fields: what is offered is overwritten by whatever the user types, and
/// the field that is emptied says so at the keyboard rather than after a
/// tap that did nothing (`PairController.localNameEdited`).
///
/// **The camera is mounted by the tap, not when the page opens.** Starting
/// `MobileScanner` is what asks the OS for the camera, so a page that built
/// it unconditionally would put a permission prompt in front of someone who
/// came to paste a line — and on a build with no camera behind the plugin,
/// which is every desktop build of this head, there would be a failing
/// widget on a page that otherwise works. The button asks for the camera
/// first, and every way the camera can fail — denied, no camera, no plugin
/// for this platform — lands as a line saying so, with the paste field still
/// right under it. Nothing on this page is ever blocked on the camera.
///
/// [onPaired] is the seam back to Devices: the controller has refreshed
/// `AppState.devices` by the time it fires, so the destination needs
/// nothing handed to it. The entrypoint wires it to a pop; this page holds
/// no `Navigator` of its own — and the confirmation naming the device it
/// paired with is shown just before, through the app's `ScaffoldMessenger`,
/// so it is still on screen once Devices is.
class PairPage extends StatefulWidget {
  const PairPage({super.key, required this.onPaired, required this.scanner});

  /// Called once after a successful pairing, when the page should leave.
  final VoidCallback onPaired;

  /// The camera, as the page's second input method — named at the route the
  /// way the scope names the real `enrolWithPeer`, so the real one is what a
  /// production build gets and a fake cannot arrive by omission.
  final PairScanner scanner;

  @override
  State<PairPage> createState() => _PairPageState();
}

class _PairPageState extends State<PairPage> {
  final _payload = TextEditingController();
  final _localName = TextEditingController();
  final _proposedName = TextEditingController();

  /// Whether the camera is on screen. Off until the user asks for it, for
  /// the reason the class doc comment gives.
  bool _scanning = false;

  /// The desktop name this page last put in the field itself, so it can tell
  /// its own offer from a name the user typed — and never overwrite the
  /// second. One string rather than a `bool edited` beside the text: the
  /// question is only ever "is the field still showing what I put there",
  /// and a flag kept in step with the text is one more thing that can drift.
  String? _offeredDesktopName;

  @override
  void initState() {
    super.initState();
    // Filled before the listeners are attached: an untouched field is not an
    // edited one, and it is editing a name away that earns the line under it.
    _proposedName.text = defaultThisDeviceName();
    _payload.addListener(_offerDesktopName);
    _localName.addListener(_localNameEdited);
    _proposedName.addListener(_proposedNameEdited);
  }

  /// The desktop names itself in the payload it printed, so the field for
  /// that name fills itself in as soon as one is readable — pasted, scanned
  /// or typed. Left alone once the user has put something else there.
  void _offerDesktopName() {
    final offered = desktopNameFromPayload(_payload.text);
    if (offered == null) return;
    if (_localName.text != (_offeredDesktopName ?? '')) return;
    _offeredDesktopName = offered;
    _localName.text = offered;
  }

  void _localNameEdited() =>
      pairScope.controller.localNameEdited(_localName.text);

  void _proposedNameEdited() =>
      pairScope.controller.proposedNameEdited(_proposedName.text);

  /// The clipboard, as the payload field's own button: the `dsync-pair:v1:`
  /// line reaches a phone by being copied out of something else, and a long
  /// press on a text field is an affordance only to someone who already
  /// knows it is there.
  ///
  /// Pasting fills the field and nothing more — the exchange still starts
  /// from the button, so a mis-paste is looked at before it is sent. The
  /// text is trimmed because a line copied out of a terminal carries the
  /// newline that ended it.
  Future<void> _paste() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text?.trim();
    if (text == null || text.isEmpty || !mounted) return;
    _payload.text = text;
  }

  @override
  void dispose() {
    _payload.dispose();
    _localName.dispose();
    _proposedName.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final controller = pairScope.controller;
    await controller.submitPayload(
      payloadText: _payload.text,
      localName: _localName.text,
      proposedName: _proposedName.text,
    );
    _leaveIfPaired(controller);
  }

  /// A scan from the camera: raw text straight to the controller, which is
  /// the only thing here that decodes or judges it.
  ///
  /// The field is filled in as well, so what a refused scan was looking at
  /// is on screen next to the reason it was refused — a code that is not
  /// ours, a code read at the wrong angle, and a code whose pairing has
  /// expired all render differently, and only some of them are worth
  /// retrying.
  Future<void> _onScanned(String raw) async {
    _payload.text = raw;
    final controller = pairScope.controller;
    await controller.onPayloadScanned(
      raw,
      localName: _localName.text,
      proposedName: _proposedName.text,
    );
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
          scanner: widget.scanner,
          onScanned: _onScanned,
          scanning: _scanning,
          onShowScanner: () => setState(() => _scanning = true),
          onHideScanner: () => setState(() => _scanning = false),
          payload: _payload,
          onPaste: _paste,
          localName: _localName,
          proposedName: _proposedName,
          onSubmit: _submit,
        ),
      ),
    );
  }
}

class _PairForm extends StatelessWidget {
  const _PairForm({
    required this.state,
    required this.scanner,
    required this.onScanned,
    required this.scanning,
    required this.onShowScanner,
    required this.onHideScanner,
    required this.payload,
    required this.onPaste,
    required this.localName,
    required this.proposedName,
    required this.onSubmit,
  });

  final PairViewState state;

  /// The camera, and where its text goes. Built only in the branch below:
  /// what mounts it is the tap, so a page that is merely open has not asked
  /// the OS for a camera.
  final PairScanner scanner;
  final ValueChanged<String> onScanned;

  final bool scanning;
  final VoidCallback onShowScanner;
  final VoidCallback onHideScanner;
  final TextEditingController payload;
  final VoidCallback onPaste;
  final TextEditingController localName;
  final TextEditingController proposedName;
  final VoidCallback onSubmit;

  @override
  Widget build(BuildContext context) {
    final submitting = state.outcome is PairSubmitting;
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        const Text(
          'On the desktop, run `dsync pair show` and paste the '
          '`dsync-pair:v1:` line it prints — or scan the QR code beside it.',
        ),
        const SizedBox(height: 16),
        if (scanning) ...[
          scanner(onScanned),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton(
              key: const Key('pair-hide-camera'),
              onPressed: onHideScanner,
              child: const Text('Hide the camera'),
            ),
          ),
        ] else
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              key: const Key('pair-show-camera'),
              onPressed: submitting ? null : onShowScanner,
              icon: const Icon(Icons.qr_code_scanner),
              label: const Text('Scan the QR code with the camera'),
            ),
          ),
        const SizedBox(height: 16),
        TextField(
          key: const Key('pair-payload'),
          controller: payload,
          enabled: !submitting,
          maxLines: null,
          decoration: InputDecoration(
            labelText: 'Pairing payload',
            hintText: 'dsync-pair:v1:…',
            suffixIcon: IconButton(
              key: const Key('pair-payload-paste'),
              onPressed: submitting ? null : onPaste,
              icon: const Icon(Icons.content_paste),
              tooltip: 'Paste',
            ),
          ),
        ),
        const SizedBox(height: 16),
        TextField(
          key: const Key('pair-local-name'),
          controller: localName,
          enabled: !submitting,
          decoration: InputDecoration(
            labelText: 'Name for the desktop',
            helperText: 'What this device will show it as.',
            errorText: state.localNameError,
          ),
        ),
        const SizedBox(height: 16),
        TextField(
          key: const Key('pair-proposed-name'),
          controller: proposedName,
          enabled: !submitting,
          decoration: InputDecoration(
            labelText: 'Name for this device',
            helperText: 'What the desktop will show this device as.',
            errorText: state.proposedNameError,
          ),
        ),
        const SizedBox(height: 24),
        _OutcomeLine(state.outcome),
        FilledButton(
          onPressed: submitting ? null : onSubmit,
          child: submitting
              ? const SizedBox(
                  width: 20,
                  height: 20,
                  // The spinner stands in for the button's 'Pair' label
                  // while the request is in flight.
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    semanticsLabel: 'Pairing',
                  ),
                )
              : const Text('Pair'),
        ),
      ],
    );
  }
}

/// The camera itself: `mobile_scanner`, and nothing between it and
/// `PairController.onPayloadScanned`.
///
/// `mobile_scanner` is the *decoder* — it reads a symbol, and this hands the
/// text on. It is not the `qr` package pinned in `pubspec.yaml`, which is the
/// *encoder* the CLI's terminal renderer draws `dsync pair show`'s symbol
/// with: one turns a payload into a symbol, the other turns a symbol back
/// into a payload, and neither replaces the other. The CLI never links this
/// one; the four v1 targets with no `app` head are untouched by it (SPEC §3).
///
/// What this widget deliberately does not do:
///
/// - No payload decode, no version check, no validation of the text. A code
///   that is not a dsync payload is a code whose text this hands over like
///   any other, and `PairingPayload.decode` decides — so a user who points
///   the camera at the wrong code gets "that is not a dsync pairing payload"
///   rather than silence.
/// - No narrowing of the reader to QR symbols either. That would be this
///   widget deciding which scans are legitimate, and there is a page already
///   showing the answer for a code that turns out not to be ours.
/// - No debounce. Frames repeat while a code is in view; the guard for that
///   is in the controller, where the state that says "in flight" and "done"
///   already lives.
///
/// When the camera cannot be used, the widget renders why in place of the
/// preview: a denied permission, no camera at all, or a platform the plugin
/// has no implementation for — which is checked rather than discovered from
/// a failed channel call, since nothing on Linux or Windows answers one and
/// an unanswered platform channel throws.
class QrScanner extends StatefulWidget {
  const QrScanner(this.onScanned, {super.key});

  /// Where a read code's text goes, raw.
  final ValueChanged<String> onScanned;

  @override
  State<QrScanner> createState() => _QrScannerState();
}

class _QrScannerState extends State<QrScanner> {
  /// The camera session. Owned here because one is passed to
  /// `MobileScanner`: given a controller of its own the widget disposes it,
  /// given this one it does not — it stops the camera on unmount and leaves
  /// the object to its owner. Disposing here is what stops the camera when
  /// the page hides it or leaves.
  final _controller = MobileScannerController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  /// The text of the first code in the frame that carries any, and nothing
  /// about the rest. One code in front of the camera is the case worth
  /// handling; a frame holding two is answered by the controller's own
  /// guard, which ignores everything after the first exchange has started.
  void _onDetect(BarcodeCapture capture) {
    for (final barcode in capture.barcodes) {
      final raw = barcode.rawValue;
      if (raw != null) {
        widget.onScanned(raw);
        return;
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!_cameraPlatform) return const _CameraNote(_noCameraHere);
    return ValueListenableBuilder<MobileScannerState>(
      valueListenable: _controller,
      builder: (context, state, _) {
        final error = state.error;
        // The preview is replaced by the reason, not covered by it: the
        // paste field under this widget is the fallback, and a note takes
        // less room than a dead rectangle.
        if (error != null) return _CameraNote(_unavailable(error.errorCode));
        // 4:3 rather than a fixed height: the `ListView` hands this all the
        // width it has and no height at all, and `MobileScanner` sizes
        // itself to the constraints it is given.
        return AspectRatio(
          aspectRatio: 4 / 3,
          child: MobileScanner(controller: _controller, onDetect: _onDetect),
        );
      },
    );
  }
}

/// Whether a camera is behind the plugin on this build: the two platforms
/// this head ships on (`app` is Android and iOS, SPEC §3), and only those.
/// The plugin also carries macOS and web code, but neither is a v1 target
/// for the head, and building the preview against a channel nothing answers
/// is a thrown platform exception rather than a failure this widget could
/// render.
bool get _cameraPlatform =>
    defaultTargetPlatform == TargetPlatform.android ||
    defaultTargetPlatform == TargetPlatform.iOS;

const _noCameraHere =
    'This build has no camera access, so the QR code cannot be scanned. '
    'Paste the `dsync-pair:v1:` line instead.';

/// What to say for a camera that is there and would not start. A denied
/// permission is the one case with a fix the user has to go and perform, so
/// it is the one case that names it; everything else is the plugin's own
/// wording, followed by the way out that is on this same page.
String _unavailable(MobileScannerErrorCode code) => switch (code) {
  MobileScannerErrorCode.permissionDenied =>
    'Dsync is not allowed to use the camera — $_permissionFix. Paste the '
        '`dsync-pair:v1:` line instead.',
  _ =>
    'The camera could not be used: ${code.message} Paste the '
        '`dsync-pair:v1:` line instead.',
};

const _permissionFix = 'allow the camera for Dsync in this device\'s settings';

/// A line where the camera preview would be: what went wrong, and what to do
/// instead. Plain on purpose — this is not an error page, it is a page that
/// still works without the camera.
class _CameraNote extends StatelessWidget {
  const _CameraNote(this.message);

  final String message;

  @override
  Widget build(BuildContext context) =>
      Text(message, style: Theme.of(context).textTheme.bodyMedium);
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
        child: Text('Connecting to the desktop…'),
      ),
      PairIdle() || PairSucceeded() => const SizedBox.shrink(),
    };
  }
}
