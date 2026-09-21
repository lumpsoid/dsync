import 'dart:io';

import 'package:dsync/dsync_core/models/host_port.dart';

/// Which host the pairing payload advertises, when the operator has already
/// said enough for there to be nothing to guess (task 2b26ac) — `null` when
/// they have not, and the caller should fall back to
/// [preferredAdvertisableAddress] over this machine's real interfaces.
///
/// Pure, and deliberately separate from the probing below: "the operator
/// chose" and "the machine was asked" are two different answers, and only
/// the second one needs a network to compute. Fetching never decides.
///
/// Two ways the choice is already made:
///
/// - **[advertise] was given** (`dsync pair show --advertise`). The operator
///   named the address the peer should dial, which is the whole point of the
///   flag — nothing here second-guesses it, including a loopback or an
///   address this machine does not currently hold, because "advertise the
///   tunnel address that is not up yet" is a legitimate thing to mean.
/// - **[bindAddress] is not a wildcard** (`--bind 10.8.0.3`). A listener
///   bound to one interface answers at exactly one address, so advertising
///   any other would advertise somewhere it is not listening. This is what
///   makes "bind it to the WireGuard address" a complete instruction rather
///   than half of one.
///
/// A wildcard bind (`0.0.0.0`, `::`) says nothing about which address a peer
/// should dial, so it is the one case that falls through to `null`.
String? chosenAdvertisableHost({
  String? advertise,
  required InternetAddress bindAddress,
}) {
  final explicit = advertise?.trim();
  if (explicit != null && explicit.isNotEmpty) return normalizedHost(explicit);
  if (isWildcardAddress(bindAddress)) return null;
  return normalizedHost(bindAddress.address);
}

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
/// not a smarter guess here — and, since task 2b26ac, not this function at
/// all when the operator has said which address to advertise or bound the
/// listener to one interface: see [chosenAdvertisableHost], which the
/// callers consult first.
///
/// Prefers IPv4 and falls back to a routable IPv6 address, so a host with
/// no IPv4 at all still advertises something dialable. Skips loopback,
/// since a loopback address is only ever useful advertised to a peer on this
/// same machine — the caller falls back to it explicitly when this returns
/// `null`, rather than this function offering it as if it were a real
/// answer.
///
/// `null` when no such address exists (a sandboxed test runner with no
/// network interfaces, a host that is briefly between interfaces) or when
/// [NetworkInterface.list] itself throws — this is advisory, so a failure
/// here must not fail the operation that asked for it.
Future<String?> preferredAdvertisableAddress() async {
  final List<NetworkInterface> interfaces;
  try {
    interfaces = await NetworkInterface.list(type: InternetAddressType.any);
  } on SocketException {
    return null;
  }
  // IPv4 first, and only then IPv6 — a guess, and the likelier one, since
  // the far end may have no IPv6 route at all. The guess is what
  // `--advertise` and a non-wildcard `--bind` exist to replace
  // ([chosenAdvertisableHost]); a host with several addresses is exactly the
  // case where no rule here can be right, and the answer is the operator
  // saying which, not a cleverer ordering.
  String? fallback;
  for (final interface in interfaces) {
    for (final address in interface.addresses) {
      if (address.isLoopback) continue;
      if (address.type == InternetAddressType.IPv4) return address.address;
      // A link-local IPv6 address (`fe80::/10`) is not dialable without the
      // scope id of the interface it belongs to, which no payload carries,
      // so it is never an answer — unlike its IPv4 counterpart, which at
      // least reaches a peer on the same segment.
      if (!address.isLinkLocal) fallback ??= address.address;
    }
  }
  return fallback;
}
