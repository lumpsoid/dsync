import 'package:material_ui/material_ui.dart';
import 'package:qr/qr.dart';

/// A QR symbol, painted from an already-encoded [QrImage] (SPEC §4.4).
///
/// The screen counterpart of `render_pairing_qr`
/// (`native/cli/src/qr.rs`): the same encoder, drawn as
/// rectangles instead of half-block glyphs. It takes the encoded image
/// rather than the payload because encoding can refuse a payload that is too
/// large, and that verdict belongs to the value the controller built
/// (`PairingOffer`), not to a `build`.
///
/// **Always black on white, in both themes.** What reads this is a camera
/// with an exposure and a contrast threshold, not a person, and a symbol
/// tinted to match a dark scheme is a symbol some cameras will not resolve.
/// The white extends [quietZoneModules] modules past the symbol on every
/// side because the quiet zone is part of the code: without it a scanner has
/// no way to find the finder patterns' edges.
class QrSymbol extends StatelessWidget {
  const QrSymbol(this.image, {super.key, this.quietZoneModules = 4});

  /// The encoded symbol to draw.
  final QrImage image;

  /// The white margin around the symbol, in modules. Four is the minimum
  /// the QR specification asks for, and what the terminal renderer uses.
  final int quietZoneModules;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: 'Pairing code as a QR symbol',
      image: true,
      child: AspectRatio(
        aspectRatio: 1,
        child: CustomPaint(
          painter: _QrPainter(image: image, quietZoneModules: quietZoneModules),
          child: const SizedBox.expand(),
        ),
      ),
    );
  }
}

class _QrPainter extends CustomPainter {
  _QrPainter({required this.image, required this.quietZoneModules});

  final QrImage image;
  final int quietZoneModules;

  @override
  void paint(Canvas canvas, Size size) {
    final modules = image.moduleCount + quietZoneModules * 2;
    final cell = size.shortestSide / modules;
    canvas.drawRect(
      Offset.zero & size,
      Paint()..color = const Color(0xFFFFFFFF),
    );
    final dark = Paint()..color = const Color(0xFF000000);
    for (var row = 0; row < image.moduleCount; row++) {
      for (var col = 0; col < image.moduleCount; col++) {
        if (!image.isDark(row, col)) continue;
        final left = (col + quietZoneModules) * cell;
        final top = (row + quietZoneModules) * cell;
        // Each module is drawn from its own floor to its neighbour's
        // ceiling, so two adjacent dark modules overlap by less than a pixel
        // rather than leaving a hairline of background between them — which
        // at small sizes is what makes a symbol fail to scan.
        canvas.drawRect(
          Rect.fromLTRB(
            left.floorToDouble(),
            top.floorToDouble(),
            (left + cell).ceilToDouble(),
            (top + cell).ceilToDouble(),
          ),
          dark,
        );
      }
    }
  }

  @override
  bool shouldRepaint(_QrPainter old) =>
      !identical(old.image, image) || old.quietZoneModules != quietZoneModules;
}
