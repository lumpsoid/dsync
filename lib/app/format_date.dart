/// A `DateTime` as a local calendar date, `YYYY-MM-DD`.
///
/// The widget layer's job, not a controller's: which calendar and which
/// order a date is spelled in is a locale question, and the row models
/// deliberately hand dates over as `DateTime`s for exactly this reason (see
/// `PairedDeviceRow.pairedAt`). One function rather than one private helper
/// per page, so the pairing date, a certificate's issue date and its expiry
/// are spelled the same way.
///
/// Kept to the day: the minute a pairing happened or a certificate was
/// issued is not something anyone acts on, and the one date that is acted
/// on — an expiry — is warned about in days by `CertificateExpiry` anyway.
///
/// Not localised. Task fc8e49 is where that happens, for every string in
/// the head at once.
String formatDate(DateTime at) {
  final local = at.toLocal();
  String two(int n) => n.toString().padLeft(2, '0');
  return '${local.year}-${two(local.month)}-${two(local.day)}';
}
