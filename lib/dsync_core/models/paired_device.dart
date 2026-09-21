import 'dart:typed_data';

import 'package:dsync/dsync_core/identity/device_id.dart';
import 'package:dsync/dsync_core/models/device_verification.dart';
import 'package:dsync/dsync_core/models/host_port.dart';

/// A host and port this installation last reached a paired device at (SPEC
/// §4.4) — seeded from the QR at pairing time and overwritten on every
/// successful connection.
///
/// Parsed at construction: [host] cannot be empty and [port] cannot be
/// outside the range a socket could ever bind or connect to, so nothing
/// downstream re-checks either — and an IPv4-mapped IPv6 literal
/// (`::ffff:a.b.c.d`, what a dual-stack listener reports for an IPv4 peer)
/// is reduced to the plain IPv4 form here, so no consumer has to know that
/// spelling exists. See [normalizedHost] for why that matters.
class PeerAddress {
  /// SPEC §4.4: unprivileged, in the registered/user range rather than the
  /// ephemeral one, and not shared with ssh, common dev servers, or
  /// Syncthing. The listener's own bound port is `d0e960`'s to configure;
  /// this is only the address book's fallback when a pairing does not say
  /// otherwise.
  static const defaultPort = 28771;

  final String host;
  final int port;

  PeerAddress({required String host, this.port = defaultPort})
    : host = normalizedHost(host.trim()) {
    if (host.trim().isEmpty) {
      throw const FormatException('Empty host');
    }
    if (port < 1 || port > 65535) {
      throw FormatException('Port out of range: $port');
    }
  }

  /// This address as one piece of text, for a message, a log line or a
  /// field the user can paste back — bracketed when [host] is an IPv6
  /// literal, so it round-trips through [parseHostPort].
  ///
  /// Not `toString()`: this is a value shown to a user, and a `toString`
  /// override is also what an accidental string interpolation of the object
  /// would pick up, which is how a debug shape ends up on screen.
  String get text => formatHostPort(host, port);
}

/// One device this installation has paired with (SPEC §4.4): the certificate
/// pinned for it, this host's own name for it, the replica roots it may
/// reach, and where it was last reached.
///
/// **Immutable, no public setters.** Every field but [lastKnownAddress] is
/// fixed for the life of a pairing — re-pointing a name at a new certificate,
/// or granting a new root, is a new [PairedDevice] the store is handed, not a
/// mutation of this one (SPEC §4.4's re-pairing case and task 83800f's grant
/// are both call sites the store's `add` composes with, not something this
/// class does to itself). [withLastKnownAddress] is the one exception, for
/// the one field that changes on its own on every successful connection.
class PairedDevice {
  /// The peer's self-signed identity certificate, PEM-encoded.
  ///
  /// PEM, not DER, for the same reason `DeviceIdentity.certificatePem` is:
  /// `SecurityContext.setTrustedCertificatesBytes` — what `d0e960` installs a
  /// pin through — reads PEM, and PEM is also the shape the certificate
  /// travels in across a
  /// pairing exchange (the QR, task 65fbb7). [certificateDer] derives the
  /// bytes `d0e960` compares `X509Certificate.der` against and [deviceId]
  /// derives its hash the same way — both unambiguous, standard PEM framing,
  /// the same derivation `DeviceIdentity` already does.
  final String certificatePem;

  /// This host's own label for the device (SPEC §4.4). Local, not agreed with
  /// the peer, and unique only within this host's own paired set — enforced
  /// by [PairedDeviceStore.add], not here: rejecting a collision needs to see
  /// every other device, which only the store has loaded.
  final String name;

  /// The expanded replica roots (`Location.expandedPath`) this device may
  /// serve (SPEC §4.4, task 83800f). A `hello` naming anything outside this
  /// set is refused. Granting is local and additive only through a fresh
  /// [PairedDevice] — nothing a peer sends over the wire ever changes its own
  /// entry.
  final Set<String> agreedReplicaRoots;

  final DateTime pairedAt;

  /// Where a connection to this device last succeeded (SPEC §4.4), seeded
  /// from the QR at pairing time. See [withLastKnownAddress].
  final PeerAddress lastKnownAddress;

  /// The user's own out-of-band check on this pairing, or `null` while they
  /// have not made one — see [DeviceVerification] and [verifiedAt].
  ///
  /// Nullable rather than a `bool` beside a date, because "verified" and
  /// "when" are one fact: a pairing either carries a comparison the user
  /// made or it does not, and a flag set with no date (or a date with the
  /// flag clear) would be a state nothing could render.
  final DeviceVerification? verification;

  PairedDevice({
    required this.certificatePem,
    required this.name,
    required Set<String> agreedReplicaRoots,
    required this.pairedAt,
    required this.lastKnownAddress,
    this.verification,
  }) : agreedReplicaRoots = Set.unmodifiable(agreedReplicaRoots) {
    if (name.trim().isEmpty) {
      throw const FormatException('Empty device name');
    }
  }

  /// This device's id (SPEC §4.4): SHA-256 of [certificatePem]'s
  /// `SubjectPublicKeyInfo`, lowercase hex in 4-character groups.
  ///
  /// Computed from [certificatePem] on every access, through the one function
  /// both our own identity's id and a peer's id go through
  /// ([deviceIdFromCertificateDer]) — not cached, and not stored on disk
  /// alongside the certificate, so there is exactly one source of truth and
  /// nothing here can hold an id that has drifted from the certificate it was
  /// built from.
  String get deviceId => deviceIdFromCertificateDer(certificateDer);

  /// [certificatePem] decoded to raw DER — what `d0e960` compares a live
  /// `X509Certificate.der` against.
  Uint8List get certificateDer => certificateDerFromPem(certificatePem);

  /// When the user confirmed this device's id out of band, or `null` when
  /// they have not — or when they did and the pairing has since been redone
  /// against a different key.
  ///
  /// Derived from [verification] against the *current* [deviceId] rather
  /// than read straight off it, so a stale confirmation cannot outlive the
  /// key it was made about: a revoke-and-re-pair produces a different id, and
  /// this goes back to `null` on its own. Renewal keeps the key, so it keeps
  /// the confirmation — which is right, since it is the key the user
  /// compared.
  DateTime? get verifiedAt {
    final made = verification;
    if (made == null || made.deviceId != deviceId) return null;
    return made.at;
  }

  /// Whether [rootPath] is one this device is agreed to reach — what a
  /// `hello` handler checks a `ReplicaSpec`'s expanded root against (SPEC
  /// §4.4).
  bool servesRoot(String rootPath) => agreedReplicaRoots.contains(rootPath);

  /// This device with [address] recorded as the last-known one, everything
  /// else unchanged — what a successful connection calls
  /// [PairedDeviceStore.recordConnection] to persist (SPEC §4.4).
  PairedDevice withLastKnownAddress(PeerAddress address) => PairedDevice(
    certificatePem: certificatePem,
    name: name,
    agreedReplicaRoots: agreedReplicaRoots,
    pairedAt: pairedAt,
    lastKnownAddress: address,
    verification: verification,
  );

  /// This device with [rootPath] added to its agreed replica roots,
  /// everything else unchanged — pairing's second step (SPEC §4.4, task
  /// 83800f), what [PairedDeviceStore.grant] (task bc68c7) persists.
  /// Additive and idempotent: a [rootPath] already in the set is not
  /// duplicated, since it is a `Set` union, not an append.
  ///
  /// [rootPath] is expected already expanded (`Location.expandedPath`) — the
  /// same form every existing entry in [agreedReplicaRoots] holds. This does
  /// not expand it itself; the caller (`dsync pair grant`) does, the same way
  /// `agent_command.dart`'s `_buildAgent` does for a `hello`'s root.
  /// This device with a renewed [certificatePem] — one carrying the same
  /// public key, so the same [deviceId] — everything else unchanged; what a
  /// connection that met a renewed certificate calls
  /// [PairedDeviceStore.recordCertificate] to persist (SPEC §4.4).
  PairedDevice withCertificatePem(String pem) => PairedDevice(
    certificatePem: pem,
    name: name,
    agreedReplicaRoots: agreedReplicaRoots,
    pairedAt: pairedAt,
    lastKnownAddress: lastKnownAddress,
    verification: verification,
  );

  PairedDevice withAdditionalRoot(String rootPath) => PairedDevice(
    certificatePem: certificatePem,
    name: name,
    agreedReplicaRoots: {...agreedReplicaRoots, rootPath},
    pairedAt: pairedAt,
    lastKnownAddress: lastKnownAddress,
    verification: verification,
  );

  /// This device with [rootPath] taken out of its agreed replica roots,
  /// everything else unchanged — the withdrawal half of [withAdditionalRoot],
  /// what [PairedDeviceStore.revokeRoot] persists.
  ///
  /// A grant is the whole of what lets a peer name a root in its `hello`
  /// (SPEC §4.4), so it has to be withdrawable by the host that made it;
  /// until now the only way back was [PairedDeviceStore.revoke], which throws
  /// the pairing away with the grant. Removing from a `Set`, so a [rootPath]
  /// that was never granted leaves the set as it was rather than failing —
  /// the post-condition a caller wants either way is "this device does not
  /// serve that root".
  PairedDevice withoutRoot(String rootPath) => PairedDevice(
    certificatePem: certificatePem,
    name: name,
    agreedReplicaRoots: {...agreedReplicaRoots}..remove(rootPath),
    pairedAt: pairedAt,
    lastKnownAddress: lastKnownAddress,
    verification: verification,
  );

  /// This device under [name], everything else unchanged — what
  /// [PairedDeviceStore.rename] persists.
  ///
  /// The name is this host's own label (see [PairedDevice.name]): changing it
  /// tells the peer nothing, moves no pin, and cannot change [deviceId],
  /// which is derived from the certificate alone. Uniqueness within the
  /// paired set is the store's to enforce, here as at [PairedDeviceStore.add],
  /// because it needs every other device to decide; an empty name is refused
  /// by the constructor as it is everywhere else.
  PairedDevice withName(String name) => PairedDevice(
    certificatePem: certificatePem,
    name: name,
    agreedReplicaRoots: agreedReplicaRoots,
    pairedAt: pairedAt,
    lastKnownAddress: lastKnownAddress,
    verification: verification,
  );

  /// This device recorded as verified at [at] — the user compared this
  /// host's [deviceId] for it against the id the device itself shows, and
  /// said they matched. What [PairedDeviceStore.recordVerification]
  /// persists.
  ///
  /// The id stamped in is [deviceId] as it is *now*, so the record is about
  /// the key currently pinned and nothing else (see [verifiedAt]).
  PairedDevice withVerification(DateTime at) => PairedDevice(
    certificatePem: certificatePem,
    name: name,
    agreedReplicaRoots: agreedReplicaRoots,
    pairedAt: pairedAt,
    lastKnownAddress: lastKnownAddress,
    verification: DeviceVerification(deviceId: deviceId, at: at),
  );

  /// This device with the user's confirmation taken back off it — the undo
  /// of [withVerification], for a check made in haste or against the wrong
  /// screen.
  ///
  /// Nothing else changes: the pairing is exactly as trusted as it was,
  /// because the confirmation was never what made it trusted (see
  /// [DeviceVerification]).
  PairedDevice withoutVerification() => PairedDevice(
    certificatePem: certificatePem,
    name: name,
    agreedReplicaRoots: agreedReplicaRoots,
    pairedAt: pairedAt,
    lastKnownAddress: lastKnownAddress,
  );
}
