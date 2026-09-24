/// A paired device as its row shows it (SPEC §4.4).
final class PairedDeviceInfo {
  const PairedDeviceInfo({
    required this.deviceId,
    required this.name,
    required this.commonName,
    required this.grantedRoots,
    required this.address,
    required this.pairedAt,
    required this.verifiedAt,
    required this.issuedAt,
    required this.expiresAt,
    required this.expiryNote,
  });

  final String deviceId;

  /// This host's own label for it.
  final String name;
  final String? commonName;

  /// Sorted and expanded, as the grants are stored.
  final List<String> grantedRoots;

  /// Where it was last reached, as the user reads and types it.
  final String address;
  final DateTime pairedAt;
  final DateTime? verifiedAt;
  final DateTime issuedAt;
  final DateTime expiresAt;
  final String? expiryNote;
}
