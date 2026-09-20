import 'package:dsync/dsync_core/identity/pairing_payload.dart';

import 'default_names.dart';

/// What the Pair page has to pair *with*: the `dsync-pair:v2:` payload the
/// user scanned or pasted, as the page shows it (SPEC §4.4).
///
/// A sealed hierarchy rather than a nullable payload beside a nullable
/// error: "read, and also unreadable" cannot be constructed, the page
/// switches over every case, and the state before anything has been
/// scanned is a case of its own rather than the absence of one.
///
/// **The base64 line itself is not part of this.** A user cannot check a
/// payload by reading it — it is a certificate, an address and a token in
/// base64 — so what the page shows is what the payload *says*: which device
/// it is and where it is. The line is kept only inside [PairCodeRead], for
/// the exchange that redeems it.
sealed class PairCode {
  const PairCode();
}

/// Nothing scanned or pasted yet. The page offers its two ways to get one
/// and shows nothing to confirm.
final class PairCodeMissing extends PairCode {
  const PairCodeMissing();
}

/// A text that is not a payload this build can use — the wrong QR code
/// entirely, a truncated paste, a version from a later release.
/// [message] is `PairingPayload.decode`'s own, which already distinguishes
/// them.
final class PairCodeUnreadable extends PairCode {
  const PairCodeUnreadable(this.message);

  final String message;
}

/// A payload that decoded: the device the user is about to pair with, and
/// where it is answering.
///
/// [desktopName] and [address] are derived at construction from [payload],
/// so the card the user reads and the exchange that follows can never be
/// describing two different devices.
final class PairCodeRead extends PairCode {
  PairCodeRead(this.payload)
    : desktopName = desktopNameFor(payload),
      address =
          '${payload.serviceAddress.host}:${payload.serviceAddress.port}';

  /// The decoded payload, redeemed by `PairController.submitPayload`.
  final PairingPayload payload;

  /// What the desktop calls itself, and so what the page offers as the name
  /// to list it under here.
  final String desktopName;

  /// `host:port` — where the desktop says it will answer from now on
  /// ([PairingPayload.serviceAddress]), not the one-shot enrolment endpoint
  /// this pairing redeems against. Shown because a device on the wrong
  /// network is the failure this flow has most of, and because this is the
  /// address the pairing leaves behind, so the user sees it before anything
  /// is sent rather than after the first sync fails.
  final String address;
}
