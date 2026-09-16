/// The expiry rule SPEC §4.4 attaches to identity certificates: when to warn
/// that one is about to expire, and what to say. Pure — a function of a
/// certificate's validity window, a clock and a threshold — so `pair list`,
/// the run header and the handshake error all say the same thing from the
/// same rule, and a test needs nothing but plain values.
library;

import 'dart:typed_data';

import 'package:dsync/dsync_core/identity/certificate_fields.dart';

/// How far ahead of a certificate's `notAfter` the warning starts (SPEC
/// §4.4). Thirty days is long enough to notice across a few weekly syncs
/// and short enough that the warning is not permanent background noise.
const defaultCertificateExpiryWindow = Duration(days: 30);

/// One certificate's standing against the clock: how long it has left, and
/// whose it is. [remaining] is negative once it has expired.
class CertificateExpiry {
  /// Whose certificate: a paired device's name, or [thisHost] for our own.
  final String owner;
  final Duration remaining;

  const CertificateExpiry({required this.owner, required this.remaining});

  static const thisHost = 'this host';

  bool get isExpired => remaining.isNegative;

  /// The warning line SPEC §4.4 asks for: `certificate for NAME expires
  /// in N days`, or `expired N days ago` once it has.
  String get message {
    final days = remaining.abs().inDays;
    final unit = days == 1 ? 'day' : 'days';
    return isExpired
        ? 'certificate for $owner expired $days $unit ago'
        : 'certificate for $owner expires in $days $unit';
  }
}

/// [der]'s expiry as seen at [now], or `null` when it is further away than
/// [window] — the one rule every warning site consults.
CertificateExpiry? certificateExpiryWithin(
  Uint8List der, {
  required String owner,
  required DateTime now,
  Duration window = defaultCertificateExpiryWindow,
}) {
  final remaining = certificateValidityFromDer(der).notAfter.difference(now);
  if (remaining > window) return null;
  return CertificateExpiry(owner: owner, remaining: remaining);
}

/// Whether [der] has expired at [now] — the handshake's own question.
bool certificateIsExpired(Uint8List der, {required DateTime now}) =>
    certificateValidityFromDer(der).notAfter.isBefore(now);
