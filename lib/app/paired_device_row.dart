import 'package:dsync/dsync_core/identity/certificate_expiry.dart';
import 'package:dsync/dsync_core/identity/certificate_fields.dart';
import 'package:dsync/dsync_core/models/paired_device.dart';

import 'format_path.dart';

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
    required this.agreedRootLabels,
    required this.certificateIssuedAt,
    required this.certificateExpiresAt,
    required this.certificateWarning,
    required this.verifiedAt,
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
      address: address.text,
      pairedAt: device.pairedAt,
      agreedRootLabels: {
        for (final root in device.agreedReplicaRoots.toList()..sort())
          root: elidePath(root),
      },
      certificateIssuedAt: validity.notBefore,
      certificateExpiresAt: validity.notAfter,
      certificateWarning: certificateExpiryWithin(
        der,
        owner: device.name,
        now: now,
      )?.message,
      verifiedAt: device.verifiedAt,
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
  /// from the peer on purpose) — each mapped to the label a one-line row
  /// shows it under. Sorted by path, so the order on screen is the set's
  /// and not the JSON document's.
  ///
  /// One map rather than a list of paths beside a list of labels: the two
  /// would be an index-alignment nobody can see, and a row whose label
  /// belongs to another path is exactly the mistake that ends in a grant
  /// withdrawn from the wrong folder. The key is the stored path, byte for
  /// byte — it is what `revokeRoot` is addressed by and what a `hello`
  /// handler compares against, so it is never elided. The value is that
  /// path through [elidePath]: every folder on a device shares a long
  /// prefix, so the end is the part that tells two of them apart.
  final Map<String, String> agreedRootLabels;

  /// The stored paths alone, in the same order. A getter over
  /// [agreedRootLabels], so a path can never be listed without its label
  /// or survive the label it was rendered from.
  List<String> get agreedRoots => agreedRootLabels.keys.toList();

  /// How many roots this host serves to the peer — what the list row shows
  /// in place of the paths themselves. A getter, so the count and the list
  /// cannot disagree.
  int get agreedRootCount => agreedRootLabels.length;

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

  /// When the user confirmed this device's id out of band, or `null` when
  /// they have not — `PairedDevice.verifiedAt`, which is already `null` for
  /// a confirmation that no longer applies to the pinned key, so nothing on
  /// screen compares ids itself.
  ///
  /// A `DateTime` rather than a rendered line, for [pairedAt]'s reason:
  /// formatting is the widget layer's. Its *absence* carries the whole of
  /// the unverified state — there is no "not verified" string here, because
  /// there is nothing to show for it. Verifying is a tool the user may
  /// reach for; not having reached for it is not a finding, and a pairing
  /// that renders a line saying so would be nagging about a choice.
  final DateTime? verifiedAt;

  /// Whether this device carries the user's confirmation — a getter over
  /// [verifiedAt], so the badge and the date can never disagree.
  bool get isVerified => verifiedAt != null;
}
