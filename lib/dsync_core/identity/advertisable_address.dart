import 'dart:io';

/// One address this machine could be reached at over the network, for the
/// pairing payload's address hint (SPEC §4.4, task bc68c7) — the one piece
/// of real I/O a pairing window needs beyond binding the enrolment listener
/// itself, kept in its own top-level function so a test hands in a fake
/// instead of depending on this machine's actual interfaces.
///
/// Lives in `dsync_core/identity/` rather than beside the CLI's
/// `systemLocalAddresses` because both heads show a pairing payload now:
/// `dsync pair show` and the Flutter head's Show-this-device's-code page
/// build the same [PairingPayload] and need the same hint, and the rule for
/// picking one belongs in one place.
///
/// Best-effort, not a promise, the same as the cache SPEC §4.4 already
/// describes: the peer's actual route may differ (NAT, a VPN, a second NIC on
/// a different subnet), and the escape hatch when it guessed wrong is the
/// same manual re-entry that section already gives a stale cached address —
/// not a smarter guess here. Prefers IPv4 (the transport
/// `EnrolmentListener.bind` and `PeerAddress` are both written against) and
/// skips loopback, since a loopback address is only ever useful advertised to
/// a peer on this same machine — the caller falls back to it explicitly when
/// this returns `null`, rather than this function offering it as if it were
/// a real answer.
///
/// `null` when no such address exists (a sandboxed test runner with no
/// network interfaces, a host that is briefly between interfaces) or when
/// [NetworkInterface.list] itself throws — this is advisory, so a failure
/// here must not fail the operation that asked for it.
Future<String?> preferredAdvertisableAddress() async {
  final List<NetworkInterface> interfaces;
  try {
    interfaces = await NetworkInterface.list(type: InternetAddressType.IPv4);
  } on SocketException {
    return null;
  }
  for (final interface in interfaces) {
    for (final address in interface.addresses) {
      if (!address.isLoopback) return address.address;
    }
  }
  return null;
}
