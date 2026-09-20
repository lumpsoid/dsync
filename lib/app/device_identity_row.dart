import 'dart:typed_data';

import 'package:dsync/dsync_core/identity/certificate_expiry.dart';
import 'package:dsync/dsync_core/identity/certificate_fields.dart';
import 'package:dsync/dsync_core/models/device_identity.dart';

/// This installation's own identity as the head displays it (SPEC §4.4,
/// §13): every field is the value a widget puts on screen, not the fact it
/// would derive it from.
///
/// The counterpart of `PairedDeviceRow`, and deliberately not a
/// [DeviceIdentity], for the same reason: a widget holding the domain object
/// is a widget that will eventually parse a certificate or re-derive the
/// SPEC §4.4 expiry rule at the widget border, once per page, drifting. The
/// parsing and the verdict happen once, here, in [render].
///
/// [issuedAt] and [expiresAt] stay `DateTime`s rather than formatted strings
/// because rendering a date is a locale question the widget layer owns —
/// the same split `PairedDeviceRow.pairedAt` makes.
class DeviceIdentityRow {
  const DeviceIdentityRow({
    required this.name,
    required this.deviceId,
    required this.issuedAt,
    required this.expiresAt,
    required this.certificateWarning,
  });

  /// [identity] as of [now]: the one place a `DeviceIdentity` becomes a row,
  /// and the one place the head consults `certificateExpiryWithin` for its
  /// *own* certificate — the same rule `pair list`, the run header and
  /// `PairedDeviceRow` consult for a peer's.
  ///
  /// A certificate whose subject carries no readable common name renders
  /// [name] as the empty string rather than throwing: the name is cosmetic
  /// (SPEC §4.4), and a device whose name cannot be read is still a device
  /// whose id, dates and expiry a user needs to see. Everything that is
  /// *not* cosmetic — the id, the validity window — is read without a
  /// fallback, because a certificate those cannot be read from is not one
  /// this head could have loaded in the first place.
  factory DeviceIdentityRow.render(
    DeviceIdentity identity, {
    required DateTime now,
  }) {
    final der = identity.certificateDer;
    final validity = certificateValidityFromDer(der);
    return DeviceIdentityRow(
      name: _commonName(der),
      deviceId: identity.deviceId,
      issuedAt: validity.notBefore,
      expiresAt: validity.notAfter,
      certificateWarning: certificateExpiryWithin(
        der,
        owner: CertificateExpiry.thisHost,
        now: now,
      )?.message,
    );
  }

  /// What this device calls itself: the subject common name of its own
  /// certificate, which is the only place that name is recorded — see
  /// `renewDeviceIdentity`'s `commonName` for what changing it costs. Empty
  /// for a certificate carrying no readable name.
  final String name;

  /// This device's id as SPEC §4.4 renders it: lowercase hex in four-char
  /// groups, ready to display and to read aloud across a pairing.
  final String deviceId;

  /// The certificate's `notBefore` — when this identity was last issued,
  /// which is when it was generated or last renewed.
  final DateTime issuedAt;

  /// The certificate's `notAfter`.
  final DateTime expiresAt;

  /// SPEC §4.4's warning line for this certificate, or `null` while its
  /// expiry is further off than the warning window. Already the line to
  /// show, not the duration to compute it from.
  final String? certificateWarning;
}

/// The certificate's own name, or `''` for a subject with none. Broad on
/// purpose, for the reason [DeviceIdentityRow.render] gives: an unreadable
/// cosmetic name must not cost the page that shows the id.
String _commonName(Uint8List der) {
  try {
    return certificateCommonNameFromDer(der);
  } on Object {
    return '';
  }
}
