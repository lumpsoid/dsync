import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:dsync/dsync_core/identity/paired_device_store.dart';
import 'package:dsync/dsync_core/models/location.dart';
import 'package:dsync/dsync_core/state_dir.dart';

/// `dsync pair grant <name> <path>` (SPEC §4.4, §11.1, task bc68c7) —
/// pairing's second step. SPEC §4.4: pairing a device and authorizing it
/// for a path are always two steps; `pair accept`/`pair show` do the first,
/// this command does the second, and both write [PairedDeviceStore].
///
/// `<path>` is expanded the same way `agent_command.dart`'s `_buildAgent`
/// expands a `hello`'s root — [Location.parse] then [Location.expandedPath]
/// against [environment] — so what lands in [PairedDeviceStore] is exactly
/// the form [PairedDevice.agreedReplicaRoots] is documented to hold and what
/// a `hello` handler will later compare a device's requested root against
/// byte for byte.
///
/// Granting is local and additive only (SPEC §4.4): nothing a peer sends
/// over the wire can add to its own entry, only an operator running this on
/// the host that owns the replica.
class PairGrantCommand extends Command<int> {
  @override
  final name = 'grant';

  @override
  final description =
      'Authorize a paired device to reach a replica root on this host '
      '(SPEC §4.4).';

  final Map<String, String> environment;
  final StateDirPlatform platform;
  final IOSink out;
  final IOSink err;

  PairGrantCommand({
    required this.environment,
    required this.platform,
    IOSink? out,
    IOSink? err,
  }) : out = out ?? stdout,
       err = err ?? stderr;

  @override
  Future<int> run() async {
    final rest = argResults!.rest;
    if (rest.length != 2) {
      usageException(
        'dsync pair grant needs exactly two arguments: the paired device\'s '
        'name (see `dsync pair list`) and the replica root path to '
        'authorize it for.',
      );
    }
    final name = rest[0];
    final rawPath = rest[1];

    final String expandedPath;
    try {
      expandedPath = Location.parse(rawPath).expandedPath(environment);
    } on FormatException catch (e) {
      usageException('dsync pair grant: not a valid path: $e');
    }

    final store = PairedDeviceStore.forStateDir(
      environment: environment,
      platform: platform,
    );
    final device = await store.byName(name);
    if (device == null) {
      // SPEC §11.5: fatal — bad arguments. Same reasoning as
      // `PairRevokeCommand`: a name that is not paired is told apart from
      // one that is, rather than silently doing nothing.
      err.writeln('dsync pair grant: no paired device named "$name".');
      return 3;
    }

    await store.grant(device.deviceId, expandedPath);
    out.writeln('granted: "$name" may now reach $expandedPath');
    return 0;
  }
}
