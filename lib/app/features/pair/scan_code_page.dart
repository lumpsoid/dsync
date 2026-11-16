import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../../pop_on_escape.dart';
import '../../readable_width.dart';

/// The camera, as the Pair flow's second input method (SPEC §4.4): built by
/// the route that opens the page (`dsync_app.dart`, from the real
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

/// The camera this build can scan with, or `null` where there is none —
/// read from the platform at this one edge and handed down as a plain value,
/// the way `PlatformFolderPicker.forThisHost` is. Production only; a test
/// hands the Pair page the case it is about directly.
///
/// A camera is behind the plugin on the two platforms this head ships on
/// (`app` is Android and iOS, SPEC §3), and only those. The plugin also
/// carries macOS and web code, but neither is a v1 target for the head;
/// turning macOS on is a matter of naming it here, and the Pair page follows
/// without a second platform check. Anywhere else, building the preview
/// against a channel nothing answers is a thrown platform exception rather
/// than a failure [QrScanner] could render — so where this is `null`, the
/// Pair page offers no scan and no scan route.
PairScanner? cameraForThisHost() => switch (defaultTargetPlatform) {
  TargetPlatform.android || TargetPlatform.iOS => QrScanner.new,
  _ => null,
};

/// The camera on a page of its own: opened by the Pair page, and closed by
/// the first code it reads, carrying that code's text back as the route's
/// result.
///
/// **A scan is an input, not a confirmation.** Reading a code here neither
/// starts the exchange nor commits to the device the code names — it fills
/// the Pair page in and leaves the user looking at what was read, with the
/// two names still theirs to change. That is the whole reason this is a
/// route rather than a preview wedged into the form: a camera in the middle
/// of a scrolling page can only announce itself by pushing the form around,
/// and a page that pairs the instant a code drifts into frame gives nobody
/// a chance to look at it.
///
/// Nothing here decodes or judges the text. A code that is not a dsync
/// payload is a code whose text this hands back like any other, and
/// `PairController.codeEntered` decides — so a user who points the camera
/// at the wrong code is told what it was, on the page that asked for it.
class ScanCodePage extends StatefulWidget {
  const ScanCodePage({super.key, required this.scanner});

  /// The camera, named at the route the way the scope names the real
  /// `enrolWithPeer`, so the real one is what a production build gets and a
  /// fake cannot arrive by omission.
  final PairScanner scanner;

  @override
  State<ScanCodePage> createState() => _ScanCodePageState();
}

class _ScanCodePageState extends State<ScanCodePage> {
  /// Whether this page has already handed a code back. `MobileScanner`
  /// reports every frame a code is in view, so one code in front of one
  /// camera is many calls per second — and each would pop a route, taking
  /// the Pair page down with the second one.
  bool _read = false;

  void _onScanned(String raw) {
    if (_read) return;
    _read = true;
    Navigator.of(context).pop(raw);
  }

  @override
  Widget build(BuildContext context) {
    return PopOnEscape(
      child: Scaffold(
        appBar: AppBar(title: const Text('Scan the pairing code')),
        body: Column(
          children: [
            // The camera takes the page: framing a small symbol is easier the
            // more of it the user can see.
            Expanded(child: Center(child: widget.scanner(_onScanned))),
            ReadableColumn(
              width: ReadableWidth.form,
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text(
                  'Point the camera at the QR code the other device is '
                  'showing.',
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The camera itself: `mobile_scanner`, and nothing between it and the text
/// it read.
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
/// - No payload decode, no version check, no validation of the text. See
///   [ScanCodePage]: the verdict belongs to the controller, on the page the
///   user came from.
/// - No narrowing of the reader to QR symbols either. That would be this
///   widget deciding which scans are legitimate, and there is a page already
///   showing the answer for a code that turns out not to be ours.
///
/// When the camera cannot be used, the widget renders why in place of the
/// preview: a denied permission, or a camera that would not start. It is
/// only ever built where the plugin has a camera behind it
/// ([cameraForThisHost]): nothing on Linux or Windows answers its channel,
/// and an unanswered platform channel throws.
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
  /// the scan page leaves.
  final _controller = MobileScannerController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  /// The text of the first code in the frame that carries any, and nothing
  /// about the rest. One code in front of the camera is the case worth
  /// handling; a frame holding two is answered by [ScanCodePage]'s own
  /// guard, which ignores everything after the first.
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
    return ValueListenableBuilder<MobileScannerState>(
      valueListenable: _controller,
      builder: (context, state, _) {
        final error = state.error;
        // The preview is replaced by the reason, not covered by it: pasting
        // the line on the page behind this one is the fallback, and a note
        // takes less room than a dead rectangle.
        if (error != null) return _CameraNote(_unavailable(error.errorCode));
        return MobileScanner(controller: _controller, onDetect: _onDetect);
      },
    );
  }
}

/// What to say for a camera that is there and would not start. A denied
/// permission is the one case with a fix the user has to go and perform, so
/// it is the one case that names it; everything else is the plugin's own
/// wording, followed by the way out on the page behind this one.
String _unavailable(MobileScannerErrorCode code) => switch (code) {
  MobileScannerErrorCode.permissionDenied =>
    'Dsync is not allowed to use the camera — $_permissionFix. Go back and '
        'paste the `dsync-pair:1.0:` line instead.',
  _ =>
    'The camera could not be used: ${code.message} Go back and paste the '
        '`dsync-pair:1.0:` line instead.',
};

const _permissionFix = 'allow the camera for Dsync in this device\'s settings';

/// A line where the camera preview would be: what went wrong, and what to do
/// instead. Plain on purpose — this is not an error page, it is a flow that
/// still works without the camera.
class _CameraNote extends StatelessWidget {
  const _CameraNote(this.message);

  final String message;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.all(24),
    child: Text(message, style: Theme.of(context).textTheme.bodyMedium),
  );
}
