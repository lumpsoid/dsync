import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:dsync/dsync_core/identity/paired_device_store.dart';
import 'package:dsync/dsync_core/state_dir.dart';

import '../options/state_dir_option.dart';

/// `dsync pair revoke <name>` (SPEC §4.4, §11.1, task bc68c7).
///
/// SPEC §4.4: "Revocation is local, not a network operation" — this writes
/// only this host's own [PairedDeviceStore], the same store [PairedDeviceStore.revoke]
/// already documents that property on. No message is sent to the revoked
/// device, by design (see that section) — nothing here should be read as an
/// oversight.
///
/// Looked up by [name] rather than device id: [name] is what a person
/// running this command actually has (`dsync pair list`'s own output), and
/// [PairedDeviceStore.byName] is the lookup that exists for exactly this.
class PairRevokeCommand extends Command<int> with StateDirOption {
  @override
  final name = 'revoke';

  @override
  final description =
      'Remove a paired device from this host\'s own store (SPEC §4.4). '
      'Local only — the far end still trusts this host until it runs the '
      'same command.';

  final Map<String, String> environment;
  final StateDirPlatform platform;
  final IOSink out;
  final IOSink err;

  PairRevokeCommand({
    required this.environment,
    required this.platform,
    IOSink? out,
    IOSink? err,
  }) : out = out ?? stdout,
       err = err ?? stderr {
    addStateDirOption();
  }

  @override
  Future<int> run() async {
    final rest = argResults!.rest;
    if (rest.length != 1) {
      usageException(
        'dsync pair revoke needs exactly one argument: the paired device\'s '
        'name (see `dsync pair list`).',
      );
    }
    final name = rest.single;

    final stateDir = stateDirOr(platform);
    final store = PairedDeviceStore.forStateDir(
      environment: environment,
      platform: stateDir,
    );
    final device = await store.byName(name);
    if (device == null) {
      // SPEC §11.5: fatal — the caller asked to revoke a specific device and
      // named one that is not paired, the same "should be told when that
      // device was never there to remove" reasoning
      // `PairedDeviceStore.revoke`'s own doc comment gives for
      // [PairedDeviceNotFoundException].
      err.writeln('dsync pair revoke: no paired device named "$name".');
      return 3;
    }

    await store.revoke(device.deviceId);
    out.writeln('revoked: $name (${device.deviceId})');
    return 0;
  }
}
