import 'package:dsync/cli/output/qr_terminal_renderer.dart';
import 'package:qr/qr.dart';
import 'package:test/test.dart';

void main() {
  group('renderQrModules', () {
    // A hand-computed "total" acceptance test (this file's own doc comment
    // claims this property for the renderer, unlike the encoder): every
    // character of the expected output is derived by hand from the mapping
    // renderQrModules documents, not read back from the function under test.
    test('single dark module surrounded by the quiet zone', () {
      bool isDark(int row, int col) => row == 0 && col == 0;

      final rendered = renderQrModules(1, isDark);
      final lines = rendered.split('\n');

      // moduleCount 1 + a 4-module quiet zone on each side = 9; 9 rows of
      // modules print as ceil(9/2) = 5 terminal lines, each 9 characters.
      expect(lines, hasLength(5));
      for (final line in lines) {
        expect(line.length, 9);
      }

      // The one dark module sits at padded (row 4, col 4) — module row 0
      // pairs with module row 1 (all light, past the grid), which prints as
      // the third terminal line ('▀' means "top half dark").
      expect(lines[0], '         ');
      expect(lines[1], '         ');
      expect(lines[2], '    ▀    ');
      expect(lines[3], '         ');
      expect(lines[4], '         ');
    });

    test('an all-light module grid renders as blank lines', () {
      final rendered = renderQrModules(1, (row, col) => false);
      expect(rendered.split('\n'), everyElement('         '));
    });

    test('all four half-block glyphs, hand-verified against a 2x2 grid', () {
      // (0,0)=false (0,1)=true
      // (1,0)=true  (1,1)=false
      const diagonal = {(0, 1), (1, 0)};
      bool isDarkDiagonal(int row, int col) => diagonal.contains((row, col));

      final rendered = renderQrModules(2, isDarkDiagonal);
      final lines = rendered.split('\n');

      // moduleCount 2 + 8 quiet-zone modules = 10; 5 printed lines of 10
      // characters. The real 2x2 grid sits at printed row index 2 (module
      // rows 4-5 in padded coordinates), columns 4-5.
      expect(lines, hasLength(5));
      expect(lines[0], '          ');
      expect(lines[1], '          ');
      // col 4: top=(0,0)=false, bottom=(1,0)=true -> '▄'
      // col 5: top=(0,1)=true, bottom=(1,1)=false -> '▀'
      expect(lines[2], '    ▄▀    ');
      expect(lines[3], '          ');
      expect(lines[4], '          ');
    });

    test('two adjacent dark module rows render as a full block', () {
      final rendered = renderQrModules(2, (row, col) => true);
      final lines = rendered.split('\n');

      expect(lines[2], '    ██    ');
    });

    test('an even module count still pads to an exact character grid', () {
      // moduleCount need not be odd for this general-purpose renderer, even
      // though every real QR symbol's is (`typeNumber * 4 + 17`) — verified
      // separately below against `package:qr`'s own output.
      final rendered = renderQrModules(6, (row, col) => false);
      final lines = rendered.split('\n');
      expect(lines, hasLength(7)); // (6 + 4*2) / 2, rounded up
      for (final line in lines) {
        expect(line.length, 14);
      }
    });
  });

  group('renderPairingQr (package:qr integration)', () {
    // These characterize the *shape* of a real encode rather than re-deriving
    // ISO/IEC 18004 correctness by hand (this file's own doc comment: that is
    // exactly what `package:qr`'s own ~18,000 lines of test-vector data
    // already do, and re-deriving it here would only prove this file agrees
    // with itself). What is checked instead is independent of this file's own
    // logic: fixed, spec-defined structural facts true of *any* valid QR
    // symbol, plus the glue between `renderPairingQr` and `renderQrModules`.
    const samplePayload = 'dsync-pair:v1:AAECAwQFBgcICQ==';

    QrImage encodeSample(
      String text, {
      QrErrorCorrectLevel level = qrErrorCorrectLevelForTerminal,
    }) => QrImage(
      QrCode(payload: QrPayload.fromString(text), errorCorrectLevel: level),
    );

    test('moduleCount follows the QR version formula', () {
      final image = encodeSample(samplePayload);
      expect(image.moduleCount, image.typeNumber * 4 + 17);
    });

    test('every one of the three finder patterns has the fixed ISO 18004 '
        'shape', () {
      final image = encodeSample(samplePayload);
      final n = image.moduleCount;

      // Each finder pattern is a 7x7 block: a dark ring on the outside edge,
      // one ring of light immediately inside it, and a dark 3x3 center. This
      // shape is fixed by the QR standard for every version and every
      // payload — it does not depend on what this task encoded.
      void expectFinderPatternAt(int top, int left) {
        for (var r = 0; r < 7; r++) {
          for (var c = 0; c < 7; c++) {
            final onOuterRing = r == 0 || r == 6 || c == 0 || c == 6;
            final onCenter = r >= 2 && r <= 4 && c >= 2 && c <= 4;
            final expectedDark = onOuterRing || onCenter;
            expect(
              image.isDark(top + r, left + c),
              expectedDark,
              reason: 'finder pattern at ($top,$left), offset ($r,$c)',
            );
          }
        }
      }

      expectFinderPatternAt(0, 0); // top-left
      expectFinderPatternAt(0, n - 7); // top-right
      expectFinderPatternAt(n - 7, 0); // bottom-left
    });

    test('a stronger error-correction level never produces a smaller symbol '
        'for the same payload', () {
      final low = encodeSample(samplePayload, level: QrErrorCorrectLevel.low);
      final medium = encodeSample(
        samplePayload,
        level: QrErrorCorrectLevel.medium,
      );
      final quartile = encodeSample(
        samplePayload,
        level: QrErrorCorrectLevel.quartile,
      );
      final high = encodeSample(samplePayload, level: QrErrorCorrectLevel.high);

      expect(low.moduleCount, lessThanOrEqualTo(medium.moduleCount));
      expect(medium.moduleCount, lessThanOrEqualTo(quartile.moduleCount));
      expect(quartile.moduleCount, lessThanOrEqualTo(high.moduleCount));
    });

    test('different payloads produce different symbols', () {
      final a = encodeSample('dsync-pair:v1:AAAA');
      final b = encodeSample('dsync-pair:v1:ZZZZZZZZZZZZZZZZZZZZZZZZZZZZ');
      expect(a.moduleCount == b.moduleCount, isFalse);
    });

    test('renders exactly what renderQrModules draws over the same symbol', () {
      final image = encodeSample(samplePayload);
      final direct = renderQrModules(image.moduleCount, image.isDark);
      expect(renderPairingQr(samplePayload), direct);
    });

    test('the rendered quiet zone is blank around a real symbol', () {
      final rendered = renderPairingQr(samplePayload);
      final lines = rendered.split('\n');

      // Two module rows of quiet zone print as one blank terminal line.
      expect(lines.first, matches(RegExp(r'^ +$')));
      expect(lines.last, matches(RegExp(r'^ +$')));
      // The left and right quiet-zone columns are blank on every line too.
      for (final line in lines) {
        expect(line.substring(0, 4), '    ');
        expect(line.substring(line.length - 4), '    ');
      }
    });

    test(
      'throws InputTooLongException for a payload no QR version can hold',
      () {
        final tooLong = 'x' * 4000;
        expect(
          () => renderPairingQr(
            tooLong,
            errorCorrectLevel: QrErrorCorrectLevel.low,
          ),
          throwsA(isA<InputTooLongException>()),
        );
      },
    );
  });

  group('qrTerminalSupported', () {
    test('false when stderr is not a real terminal at all', () {
      expect(
        qrTerminalSupported(
          hasTerminal: false,
          termEnvironmentVariable: 'xterm',
        ),
        isFalse,
      );
    });

    test('false when TERM is unset', () {
      expect(
        qrTerminalSupported(hasTerminal: true, termEnvironmentVariable: null),
        isFalse,
      );
    });

    test('false when TERM is the empty string', () {
      expect(
        qrTerminalSupported(hasTerminal: true, termEnvironmentVariable: ''),
        isFalse,
      );
    });

    test('false when TERM says dumb', () {
      expect(
        qrTerminalSupported(hasTerminal: true, termEnvironmentVariable: 'dumb'),
        isFalse,
      );
    });

    test('true for a real terminal with an ordinary TERM', () {
      expect(
        qrTerminalSupported(
          hasTerminal: true,
          termEnvironmentVariable: 'xterm-256color',
        ),
        isTrue,
      );
    });
  });
}
