/// This device's identity as its row shows it: its id, the name its
/// certificate carries, the certificate's window, and SPEC §4.4's expiry
/// warning when one is due.
final class DeviceIdentityInfo {
  const DeviceIdentityInfo({
    required this.deviceId,
    required this.commonName,
    required this.issuedAt,
    required this.expiresAt,
    required this.expiryNote,
  });

  final String deviceId;
  final String? commonName;
  final DateTime issuedAt;
  final DateTime expiresAt;
  final String? expiryNote;
}
