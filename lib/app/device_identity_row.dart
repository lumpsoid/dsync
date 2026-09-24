import 'core_link/models/device_identity_info.dart';

/// This installation's own identity as the head displays it (SPEC §4.4,
/// §13): every field is the value a widget puts on screen, not the fact it
/// would derive it from.
///
/// The counterpart of `PairedDeviceRow`: the core has already read the
/// certificate and applied the SPEC §4.4 expiry rule, and [render] is the
/// one place its answer becomes what a widget shows.
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

  /// [identity] as the core read it: its certificate's own name (empty
  /// when the certificate carries none - the name is cosmetic, SPEC §4.4),
  /// its id, its validity window and the expiry warning the core wrote
  /// when one is due.
  factory DeviceIdentityRow.render(DeviceIdentityInfo identity) =>
      DeviceIdentityRow(
        name: identity.commonName ?? '',
        deviceId: identity.deviceId,
        issuedAt: identity.issuedAt,
        expiresAt: identity.expiresAt,
        certificateWarning: identity.expiryNote,
      );

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
