/// Renders `PairingPayload.encode()`'s ASCII string (SPEC §4.4) as a QR
/// symbol drawn with Unicode half-block characters, for `dsync pair show`
/// (task e17997). Two responsibilities, kept apart the way the task itself
/// splits them: [renderPairingQr] turns the payload string into a symbol,
/// [renderQrModules] turns any symbol-shaped grid into terminal text.
///
/// **Encoder: `package:qr` (pinned `4.0.0` in `pubspec.yaml`), not
/// hand-rolled.** This is the dependency-vs-hand-roll call task e17997 says
/// is this task's to make, in the register `self_signed_certificate.dart`
/// already uses for the same kind of tradeoff — and it comes out the
/// opposite way here, for a reason that register itself supplies.
///
/// `self_signed_certificate.dart`'s own doc comment gives the reason it was
/// safe to hand-roll the X.509 assembly: "the acceptance test is total —
/// BoringSSL either completes a mutually-authenticated handshake with these
/// bytes or it does not. There is no subtly-wrong-but-working state." SPEC
/// §4.4 makes the same argument for choosing TLS over a hand-written Noise
/// handshake: "two copies of the same bug still complete a handshake with
/// each other, and the failure is silent and security-relevant rather than a
/// thrown `HandshakeException`."
///
/// A QR encoder sits on the Noise side of that line, not the certificate
/// side. Reed-Solomon error correction — the substantive part of ISO/IEC
/// 18004, and what task e17997 itself names as "the substantive part" of a
/// hand-roll — exists specifically so a symbol keeps scanning *despite* a
/// wrong module, a wrong mask-pattern score, or a miscalculated error
/// codeword. That is exactly the "subtly wrong but working" failure mode
/// `self_signed_certificate.dart` identifies as the reason not to hand-roll:
/// a version-selection off-by-one, a GF(256) table typo, or a mask-scoring
/// bug could still produce a symbol that scans on some phones, some of the
/// time, and silently fails on others — there is no BoringSSL-shaped gate
/// that turns "wrong" into "refuses to load" the way a bad certificate gets
/// one. Owning that surface for real — all 40 versions' alignment-pattern
/// geometry, mode segmentation (numeric/alphanumeric/byte/ECI), and the
/// eight mask patterns' scoring rules, not just the Reed-Solomon math — is
/// not "a few hundred lines" once measured against a real implementation:
/// `package:qr`'s own `lib/src/` is ~2,500 lines, validated against ~18,000
/// lines of test-vector data in its own test suite. That is a bigger, more
/// fiddly surface than the ~170-line X.509 encoder was, guarding a property
/// (silent partial scannability) unit tests over plain values cannot
/// exhaustively catch the way "BoringSSL accepted it" catches a certificate
/// bug — so this is the one place in the pairing feature where owning the
/// code costs more than it buys, the mirror image of the certificate case.
///
/// **What the dependency actually pulls in.** Pure Dart — no `dart:ffi`, no
/// Flutter SDK import — with exactly one runtime dependency, `meta`, which
/// was already resolved into this project transitively through `flutter`
/// itself before this task (`pubspec.lock` gained one new entry, `qr`
/// itself, when it was added; every other line was unchanged). It declares
/// support for all six pub.dev platform tags (Android, iOS, Linux, macOS,
/// Windows, Web), a superset of SPEC §3's five v1 targets, so it runs
/// identically on every target the `cli` head reaches and on the `app` head
/// too, should this renderer's sibling ever be needed there.
///
/// **The terminal renderer below is this file's own code, and its
/// acceptance test really is total**, unlike the encoder's: a hand-computed
/// small module grid maps to exactly one expected string of half-block
/// characters, with no scanner-dependent "mostly works" in between — see
/// `test/cli/output/qr_terminal_renderer_test.dart`.
library;

import 'dart:io';

import 'package:qr/qr.dart';

/// SPEC §4.4's QR carries the enrolling host's certificate DER, an address
/// hint, and a token — a few hundred bytes of base64, per
/// `pairing_payload.dart`'s own worked example (a P-256 self-signed
/// certificate's DER, encoded, comes to roughly 500 ASCII characters
/// end to end). Measured against `package:qr`'s four levels for that size:
/// [QrErrorCorrectLevel.low] (~7% recovery) keeps the symbol at version 15
/// (77x77 modules, 85 with the quiet zone below) where every stronger level
/// pushes past 100 modules and does not comfortably fit an 80-column
/// terminal. The tradeoff low error correction usually costs — resilience
/// against a damaged or degraded *printed* code — is not the risk profile
/// here: a terminal-rendered symbol is read once, immediately, off a clean
/// digital display, not off a smudged, folded, or sun-bleached printout, so
/// the scenarios higher levels protect against barely apply. `qrencode(1)`,
/// the reference CLI QR tool, defaults to the same level for the same
/// reason.
const qrErrorCorrectLevelForTerminal = QrErrorCorrectLevel.low;

/// The minimum quiet zone ISO/IEC 18004 requires around a symbol: four
/// modules of light space on every side, without which a scanner cannot
/// reliably find the finder patterns against whatever surrounds the code
/// (in a terminal, whatever else is on screen above, below, and beside it).
const _quietZoneModules = 4;

/// Encodes [payload] as a QR symbol at [errorCorrectLevel] (default
/// [qrErrorCorrectLevelForTerminal]) and renders it for a terminal via
/// [renderQrModules].
///
/// Throws [InputTooLongException] — `package:qr`'s own type — if [payload]
/// does not fit in a version-40 symbol at [errorCorrectLevel]; every real
/// `PairingPayload.encode()` output is a few hundred characters and fits
/// comfortably (version 40 holds up to 2,953 bytes at
/// [QrErrorCorrectLevel.low]), but `PairingPayload`'s own length caps
/// (64KiB certificate, 255-byte host, 255-byte token) are wider than a QR
/// symbol's absolute ceiling, so a caller three orders of magnitude outside
/// what real pairing traffic ever produces gets a named exception to catch
/// rather than this function silently truncating or crashing further down.
String renderPairingQr(
  String payload, {
  QrErrorCorrectLevel errorCorrectLevel = qrErrorCorrectLevelForTerminal,
}) {
  final code = QrCode(
    payload: QrPayload.fromString(payload),
    errorCorrectLevel: errorCorrectLevel,
  );
  final image = QrImage(code);
  return renderQrModules(image.moduleCount, image.isDark);
}

/// Draws any QR-shaped module grid — [moduleCount] modules per side,
/// [isDark] answering true/false for a module at `(row, col)`, the exact
/// shape [QrImage] itself exposes — as terminal text: two rows of modules
/// per printed line, via the Unicode half-block characters, with
/// [_quietZoneModules] of padding on every side.
///
/// Takes `(int, bool Function(int, int))` rather than a [QrImage] directly
/// so this half is testable against a hand-built grid with no dependency on
/// `package:qr`'s own encoding being correct — see this function's own test,
/// which is exactly the "acceptance test is total" property this file's doc
/// comment claims for it.
///
/// One printed character encodes one pair of vertically-adjacent modules:
/// - both light → `' '`
/// - top dark, bottom light → `'▀'` (upper half block)
/// - top light, bottom dark → `'▄'` (lower half block)
/// - both dark → `'█'` (full block)
///
/// This relies on nothing but the glyphs themselves — no ANSI color escape
/// is written, so a terminal's ordinary foreground-on-background rendering
/// is what draws "dark" as ink and "light" as background. [moduleCount] is
/// always odd for a real QR symbol (`typeNumber * 4 + 17`), and the quiet
/// zone adds an even number of modules per side, so the padded grid's total
/// height stays odd; the last printed row's bottom half is therefore always
/// the padding past the grid rather than the symbol itself, which comes out
/// as light without a separate case — see [_isDarkPadded].
String renderQrModules(
  int moduleCount,
  bool Function(int row, int col) isDark,
) {
  final size = moduleCount + _quietZoneModules * 2;
  bool paddedIsDark(int row, int col) =>
      _isDarkPadded(moduleCount, isDark, row, col);

  final lines = <String>[];
  for (var row = 0; row < size; row += 2) {
    final line = StringBuffer();
    for (var col = 0; col < size; col++) {
      final top = paddedIsDark(row, col);
      final bottom = paddedIsDark(row + 1, col);
      line.write(switch ((top, bottom)) {
        (false, false) => ' ',
        (true, false) => '▀',
        (false, true) => '▄',
        (true, true) => '█',
      });
    }
    lines.add(line.toString());
  }
  return lines.join('\n');
}

/// [isDark], reframed over the quiet-zone-padded coordinate space
/// [renderQrModules] draws in: light (`false`) for anything in the padding
/// or past the grid entirely, [isDark]'s own answer for anything inside the
/// real symbol.
bool _isDarkPadded(
  int moduleCount,
  bool Function(int row, int col) isDark,
  int row,
  int col,
) {
  final r = row - _quietZoneModules;
  final c = col - _quietZoneModules;
  if (r < 0 || c < 0 || r >= moduleCount || c >= moduleCount) return false;
  return isDark(r, c);
}

/// Whether a terminal can be assumed to render [renderQrModules]'s output
/// faithfully — a pure function of two already-resolved values, matching
/// this project's "resolved once at the CLI edge, threaded down as a value"
/// convention (`host_platform.dart`, `SyncRunner.buildInteractivePresenter`'s
/// own doc comment), so this is testable without a real terminal.
///
/// **The check: a real terminal, and a `TERM` that does not say "dumb" or
/// nothing.** The same `isatty() && TERM != dumb` heuristic coreutils, git,
/// and cargo already use to gate advanced terminal output — not a genuine
/// Unicode-rendering probe (`dart:io` has no portable one to offer), but the
/// same standard, precedented stand-in those tools rely on for the same
/// question. It is deliberately conservative in one specific direction: on
/// Windows, neither `cmd.exe` nor a native PowerShell console host sets
/// `TERM` at all (it is a Unix convention), so this treats every plain
/// Windows console as unsupported, including modern ones whose UTF-8
/// codepage would in fact render the glyphs correctly — false negatives
/// (a capable terminal gets the fallback) rather than false positives (an
/// incapable one gets mojibake nobody can scan), the same asymmetry this
/// project already prefers elsewhere (a truncated pairing payload is a
/// thrown [FormatException], never a best-effort partial parse). A terminal
/// that sets `TERM` deliberately (Windows Terminal profiles, WSL, Git Bash,
/// any real Unix shell) is read for what it says.
bool qrTerminalSupported({
  required bool hasTerminal,
  required String? termEnvironmentVariable,
}) {
  if (!hasTerminal) return false;
  final term = termEnvironmentVariable;
  return term != null && term.isNotEmpty && term != 'dumb';
}

/// The one piece of real I/O [qrTerminalSupported] needs — whether [stderr]
/// (where `dsync pair show` writes the QR, SPEC §11.4) is a real terminal —
/// kept in its own top-level function for the same reason
/// `local_addresses.dart`'s functions are: a test hands in a fake instead of
/// depending on this process's real streams.
bool stderrHasTerminal() => stderr.hasTerminal;
