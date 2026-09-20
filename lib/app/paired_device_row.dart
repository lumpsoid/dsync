import 'package:dsync/dsync_core/identity/certificate_expiry.dart';
import 'package:dsync/dsync_core/identity/certificate_fields.dart';
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
    required this.agreedRoots,
    required this.certificateIssuedAt,
    required this.certificateExpiresAt,
    required this.certificateWarning,
  });

  /// [device] as of [now]: the one place a `PairedDevice` becomes a row,
  /// and the one place the head consults `certificateExpiryWithin` for a
  /// peer — the same rule `pair list` and the run header use.
  factory PairedDeviceRow.render(PairedDevice device, {required DateTime now}) {
    final address = device.lastKnownAddress;
    final der = device.certificateDer;
    final validity = certificateValidityFromDer(der);
    return PairedDeviceRow(
      name: device.name,
      deviceId: device.deviceId,
      address: '${address.host}:${address.port}',
      pairedAt: device.pairedAt,
      agreedRoots: device.agreedReplicaRoots.toList()..sort(),
      certificateIssuedAt: validity.notBefore,
      certificateExpiresAt: validity.notAfter,
      certificateWarning: certificateExpiryWithin(
        der,
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

  /// The replica roots *this* device has granted the peer — what this host
  /// serves to it, never what the peer serves back (SPEC §4.4 keeps that
  /// from the peer on purpose). Sorted, so the order on screen is the set's
  /// and not the JSON document's.
  ///
  /// The whole set rather than a count, now that the head grants and
  /// withdraws them itself: a count is what a list row shows, and the paths
  /// are what the device's own page shows.
  final List<String> agreedRoots;

  /// How many roots this host serves to the peer — what the list row shows
  /// in place of the paths themselves. A getter, so the count and the list
  /// cannot disagree.
  int get agreedRootCount => agreedRoots.length;

  /// The pinned certificate's `notBefore` — when the peer last issued the
  /// identity this host holds for it. A pairing whose certificate has since
  /// been renewed on the peer shows the date this host *knows about*, which
  /// is the honest answer: the renewed bytes arrive only when the peer next
  /// connects here (SPEC §4.4).
  final DateTime certificateIssuedAt;

  /// The pinned certificate's `notAfter`.
  final DateTime certificateExpiresAt;

  /// SPEC §4.4's warning line for this device's certificate, or `null`
  /// while its expiry is further off than the warning window.
  final String? certificateWarning;
}
