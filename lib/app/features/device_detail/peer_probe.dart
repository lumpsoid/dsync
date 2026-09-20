import 'dart:io';

import 'package:dsync/dsync_core/models/device_identity.dart';
import 'package:dsync/dsync_core/models/paired_device.dart';
import 'package:dsync/dsync_core/protocol/socket_channel.dart';

import '../run/replica_connector.dart' show ReplicaConnector;

/// What dialing a paired device establishes, and nothing more (SPEC §4.4).
///
/// Three cases rather than a `bool` with a message beside it, because the
/// three have three different remedies and the Device page has to say which:
/// an address to correct, a peer to start, or a pairing to redo. Collapsing
/// the certificate case into "unreachable" would send the user to re-type an
/// address that was right.
sealed class PeerProbeResult {
  const PeerProbeResult();
}

/// The address answered and the far end presented a certificate carrying the
/// key this host pinned for the device (SPEC §4.4 pins the key, not the
/// bytes, which is what lets a peer renew without re-pairing).
///
/// **What this does not establish.** Under TLS 1.3 this side can finish its
/// own half of the handshake before the far end has judged *our* certificate
/// — the trap `SocketChannel.connectSecure` documents — so a peer that has
/// revoked this device, or that still pins a certificate this device has
/// since renewed, can answer a probe and still refuse a run. The probe
/// reports what a dial can honestly know; the refusal surfaces on the run.
final class PeerReachable extends PeerProbeResult {
  const PeerReachable();
}

/// Nothing answered at the address within [SocketPeerProbe.timeout], or the
/// answer was not a listening agent. [cause] is the transport's own — a
/// [SocketException] names the errno a user can act on ("connection
/// refused" and "no route to host" are different problems).
final class PeerUnreachable extends PeerProbeResult {
  const PeerUnreachable(this.cause);

  final Object cause;
}

/// The address answered, and the certificate it presented is not the one
/// pinned here: either a different key — another device at that address, or
/// a peer re-paired from scratch — or the pinned key on a certificate past
/// its `notAfter`. [detail] carries which, in `core`'s own words where it
/// has them.
///
/// Deliberately not [PeerUnreachable]: the address is right and the fix is
/// on the pairing, not on the address.
final class PeerCertificateRefused extends PeerProbeResult {
  const PeerCertificateRefused(this.detail);

  final String detail;
}

/// Dials a paired device to find out whether it is reachable at an address,
/// and nothing else — no session, no `hello`, no replica.
///
/// An interface, and the Device controller takes one as a constructor
/// argument, for the reason `app_scope.dart` states: this is a socket, the
/// one thing in the check that a widget test cannot run. The production
/// implementation is [SocketPeerProbe].
///
/// **Why not `ReplicaConnector`.** That class belongs to the Run feature and
/// a connect there is not a probe: it takes the replica lock, opens the
/// archive and builds both agents before the dial, so a probe run through it
/// would contend with a run in flight over files that run owns. What the
/// question "is the peer reachable" needs is the dial alone, which is the
/// handful of lines below.
abstract interface class PeerProbe {
  /// Dials [address] expecting the device pinned to [expectedPeerDeviceId],
  /// presenting [ownIdentity] as this device's client credential, and
  /// judges the presented certificate's expiry against [now].
  ///
  /// Every transport failure comes back as a [PeerProbeResult] case; only a
  /// defect throws. Whatever is opened is closed before this returns — a
  /// probe leaves nothing behind for a run to trip over.
  Future<PeerProbeResult> probe({
    required PeerAddress address,
    required String expectedPeerDeviceId,
    required DeviceIdentity ownIdentity,
    required DateTime now,
  });
}

/// The real [PeerProbe]: `SocketChannel.connectSecure`, closed immediately.
///
/// The same dial the Run feature makes (`dialPeer`), against the same
/// pinning hook, so "reachable" here means reachable for a run — a probe
/// that used a laxer check would report a peer a run then refuses.
final class SocketPeerProbe implements PeerProbe {
  const SocketPeerProbe();

  /// Bounds the dial, so an address that drops packets rather than refusing
  /// fails in front of the user instead of waiting out the OS's TCP retry
  /// budget. `ReplicaConnector`'s own bound, read from there rather than
  /// repeated, so a probe and the run it predicts wait the same.
  static const timeout = ReplicaConnector.peerConnectTimeout;

  @override
  Future<PeerProbeResult> probe({
    required PeerAddress address,
    required String expectedPeerDeviceId,
    required DeviceIdentity ownIdentity,
    required DateTime now,
  }) async {
    final SocketChannel channel;
    try {
      channel = await SocketChannel.connectSecure(
        address.host,
        address.port,
        expectedPeerDeviceId: expectedPeerDeviceId,
        ownIdentity: ownIdentity,
        now: now,
      ).timeout(timeout);
    } on PeerCertificateExpiredException catch (e) {
      return PeerCertificateRefused(e.toString());
    } on HandshakeException catch (e) {
      return PeerCertificateRefused(e.message);
    } catch (error) {
      return PeerUnreachable(error);
    }
    await channel.close();
    return const PeerReachable();
  }
}
