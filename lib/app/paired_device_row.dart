import 'package:dsync/dsync_core/identity/certificate_expiry.dart';
import 'package:dsync/dsync_core/models/paired_device.dart';

/// One paired device as the head displays it (SPEC §4.4, §13): every field
/// is the value a widget puts on screen, not the fact it would derive it
/// from.
///
/// Deliberately not a `PairedDevice`. A widget that holds one is a widget
/// that will eventually branch on it — `if (device.isExpired)`, a
/// re-derivation of the SPEC §4.4 expiry rule at the widget border, one
/// per page, drifting. So the branch happens once, here, in [render]: the
/// row carries the *rendered* warning or its absence, and a page only
/// decides whether there is a line to show. The fields are `String`, `int`
/// and `DateTime` by construction; nothing from `dsync_core` crosses into
/// `AppState`.
///
/// [pairedAt] stays a `DateTime` rather than a formatted string because
/// its rendering is a locale question the widget layer owns; nothing about
/// it is a domain decision.
class PairedDeviceRow {
  const PairedDeviceRow({
    required this.name,
    required this.deviceId,
    required this.address,
    required this.pairedAt,
    required this.agreedRootCount,
    required this.certificateWarning,
  });

  /// [device] as of [now]: the one place a `PairedDevice` becomes a row,
  /// and the one place the head consults `certificateExpiryWithin` for a
  /// peer — the same rule `pair list` and the run header use.
  factory PairedDeviceRow.render(PairedDevice device, {required DateTime now}) {
    final address = device.lastKnownAddress;
    return PairedDeviceRow(
      name: device.name,
      deviceId: device.deviceId,
      address: '${address.host}:${address.port}',
      pairedAt: device.pairedAt,
      agreedRootCount: device.agreedReplicaRoots.length,
      certificateWarning: certificateExpiryWithin(
        device.certificateDer,
        owner: device.name,
        now: now,
      )?.message,
    );
  }

  final String name;

  /// SPEC §4.4's grouped hex, exactly as `PairedDevice.deviceId` renders
  /// it — the same string a `revoke` is addressed by.
  final String deviceId;

  /// `host:port`, the peer's last known address as one displayable line.
  final String address;

  final DateTime pairedAt;

  /// How many replica roots have been agreed with this device. Zero is a
  /// fact worth showing — SPEC §4.4's two-step rule pairs a device before
  /// granting it anything — not an absence.
  final int agreedRootCount;

  /// SPEC §4.4's warning line for this device's certificate, or `null`
  /// while its expiry is further off than the warning window.
  final String? certificateWarning;
}
