import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:dsync/dsync_core/identity/device_identity_store.dart';
import 'package:dsync/dsync_core/models/device_identity.dart';
import 'package:dsync/dsync_core/state_dir.dart';

import '../options/state_dir_option.dart';

/// `dsync pair renew` (SPEC §4.4, §11.1) — re-issues this host's identity
/// certificate under its existing private key, so the device id every peer
/// pinned stays the same and no pairing has to be redone. Prints that id
/// back as the confirmation that nothing moved.
///
/// Never automatic: a credential other machines pin is rotated only when an
/// operator asks, so the moment it changed is something they saw. Peers
/// learn the renewed certificate the next time they connect *to* this host
/// (`connected_replicas.dart` stores what a pinned key presents); until each
/// has, this host cannot connect to it — BoringSSL on the far end anchors on
/// the bytes it holds — which the output says.
class PairRenewCommand extends Command<int> with StateDirOption {
  @override
  final name = 'renew';

  @override
  final description =
      "Re-issue this host's identity certificate under its existing key "
      '(SPEC §4.4). The device id does not change; paired devices keep '
      'their pairing.';

  final Map<String, String> environment;
  final StateDirPlatform platform;
  final IOSink out;
  final IOSink err;

  PairRenewCommand({
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
    if (argResults!.rest.isNotEmpty) {
      usageException('dsync pair renew takes no arguments.');
    }

    final stateDir = stateDirOr(platform);
    final store = DeviceIdentityStore.forStateDir(
      environment: environment,
      platform: stateDir,
    );
    final DeviceIdentity renewed;
    try {
      renewed = await store.renew();
    } on DeviceIdentityIncompleteException catch (e) {
      err.writeln('dsync pair renew: $e');
      return 3; // SPEC §11.5: fatal — there is no identity to renew.
    }

    out.writeln('renewed: device id ${renewed.deviceId} (unchanged)');
    out.writeln(
      'Paired devices pick the new certificate up the next time they '
      'connect to this host; until each has, syncs started from here to '
      'that device are refused.',
    );
    return 0;
  }
}
