import 'package:qr/qr.dart';

/// What this device is offering while its pairing window is open: the
/// `dsync-pair:v2:` line another device redeems, and the symbol that carries
/// the same line to a camera (SPEC §4.4).
///
/// The two are one value because they are one payload: a page that encoded
/// the line into a symbol itself could render a code that says something
/// other than the line printed under it, and the whole point of showing both
/// is that they are interchangeable.
///
/// **The symbol is encoded here, at construction.** `QrCode` refuses a
/// payload larger than a QR can carry ([InputTooLongException]), which is a
/// verdict about this value rather than a rendering problem, so it is
/// answered once here — [symbol] is `null` and the page says to use the line
/// instead — rather than thrown out of a `build`.
final class PairingOffer {
  PairingOffer._({
    required this.payloadLine,
    required this.address,
    required this.expiresAt,
    required this.symbol,
  });

  /// Encodes [payloadLine] into a symbol, or records that it will not fit
  /// into one.
  factory PairingOffer.forPayload(
    String payloadLine, {
    required String address,
    required DateTime expiresAt,
  }) {
    QrImage? symbol;
    try {
      symbol = QrImage(
        QrCode(
          payload: QrPayload.fromString(payloadLine),
          errorCorrectLevel: qrErrorCorrectLevelForScreen,
        ),
      );
    } on InputTooLongException {
      symbol = null;
    }
    return PairingOffer._(
      payloadLine: payloadLine,
      address: address,
      expiresAt: expiresAt,
      symbol: symbol,
    );
  }

  /// The payload as `PairingPayload.encode` spells it — what the other
  /// device's Pair page pastes, and what `dsync pair accept` takes as its
  /// argument.
  final String payloadLine;

  /// `host:port` of the enrolment endpoint this offer is being served from
  /// — the address hint inside the payload, shown because "the other device
  /// cannot reach this one" is the failure this flow has most of, and the
  /// hint is the first thing to check against the network both devices are
  /// actually on.
  final String address;

  /// When the token stops being redeemable (SPEC §4.4's short window).
  final DateTime expiresAt;

  /// The encoded symbol, or `null` when the payload is larger than a QR can
  /// carry — see the class doc comment.
  final QrImage? symbol;
}

/// The error-correction level the on-screen symbol is encoded at.
///
/// The same level, for the same reason, as
/// `TERMINAL_EC_LEVEL` (`native/cli/src/qr.rs`,
/// whose doc comment carries the measured sizing): a payload of a few
/// hundred base64 characters stays at a module count a phone camera resolves
/// comfortably, and the resilience stronger levels buy is resilience against
/// a *printed* code that has been folded or bleached. This one is read once,
/// immediately, off a lit screen.
const qrErrorCorrectLevelForScreen = QrErrorCorrectLevel.low;
