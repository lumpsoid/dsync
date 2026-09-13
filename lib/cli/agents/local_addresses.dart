import 'dart:io';

/// The set of addresses that resolve to this machine, for a location's
/// `classify` call (SPEC §4.1: "an address of this machine" runs in-process).
///
/// The one piece of real I/O `resolveReplicaAgents` needs — everything else
/// in `lib/cli/agents/` decides from values already in hand — kept in its
/// own top-level function so a test can pass a fake in its place instead of
/// touching the network.
Future<Set<String>> systemLocalAddresses() async {
  final interfaces = await NetworkInterface.list();
  return {
    for (final interface in interfaces)
      for (final address in interface.addresses) address.address,
  };
}
