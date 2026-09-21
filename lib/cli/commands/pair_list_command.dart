import 'dart:convert';
import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:dsync/dsync_core/identity/certificate_expiry.dart';
import 'package:dsync/dsync_core/identity/device_identity_store.dart';
import 'package:dsync/dsync_core/identity/paired_device_store.dart';
import 'package:dsync/dsync_core/models/paired_device.dart';
import 'package:dsync/dsync_core/state_dir.dart';

import '../options/state_dir_option.dart';

/// `dsync pair list` (SPEC §4.4, §11.1, §11.4, task bc68c7) — every device
/// this installation has paired with. Read-only: this is the one `pair`
/// subcommand with no side effect on [PairedDeviceStore] at all.
///
/// `--json` per SPEC §11.4: "a pairing list is exactly what a wrapper script
/// wants to read" (task bc68c7's own description). One JSON object per line,
/// matching `JsonRenderer`'s own shape, though this list is not a
/// `RunEvent` stream and so is not [JsonRenderer]'s job — there is no run in
/// progress here, only a store to read.
class PairListCommand extends Command<int> with StateDirOption {
  @override
  final name = 'list';

  @override
  final description = 'List paired devices (SPEC §4.4).';

  static const _flagJson = 'json';

  final Map<String, String> environment;
  final StateDirPlatform platform;
  final IOSink out;
  final IOSink err;

  /// The clock the expiry warnings read (SPEC §4.4); injectable so a test
  /// can stand at a date of its choosing.
  final DateTime Function() now;

  PairListCommand({
    required this.environment,
    required this.platform,
    IOSink? out,
    IOSink? err,
    this.now = DateTime.now,
  }) : out = out ?? stdout,
       err = err ?? stderr {
    addStateDirOption();
    argParser.addFlag(
      _flagJson,
      negatable: false,
      help: 'Machine-readable output (JSON Lines) on stdout (SPEC §11.4).',
    );
  }

  @override
  Future<int> run() async {
    if (argResults!.rest.isNotEmpty) {
      usageException('dsync pair list takes no arguments.');
    }

    final stateDir = stateDirOr(platform);
    final devices = await PairedDeviceStore.forStateDir(
      environment: environment,
      platform: stateDir,
    ).load();

    if (argResults!.flag(_flagJson)) {
      for (final device in devices) {
        out.writeln(jsonEncode(_deviceToJson(device)));
      }
    } else if (devices.isEmpty) {
      out.writeln('No paired devices.');
    } else {
      for (final device in devices) {
        final roots = device.agreedReplicaRoots.isEmpty
            ? '(no replica roots granted — see `dsync pair grant`)'
            : device.agreedReplicaRoots.join(', ');
        out.writeln(
          '${device.name}  ${device.deviceId}  '
          '${device.lastKnownAddress.text}  '
          'roots: $roots',
        );
      }
    }
    await _warnOfExpiry(devices, stateDir);
    return 0; // SPEC §11.5: listing never fails on its own account.
  }

  /// SPEC §4.4's expiry warning, for this host's own certificate and each
  /// paired peer's, on stderr in both modes: human text that must not land
  /// in a `--json` stream (§11.4), and a warning rather than a fact of the
  /// list in the other. Own identity read only if one exists — listing on a
  /// host that has never paired should not mint an identity as a side
  /// effect.
  Future<void> _warnOfExpiry(
    List<PairedDevice> devices,
    StateDirPlatform stateDir,
  ) async {
    final at = now();
    final ownStore = DeviceIdentityStore.forStateDir(
      environment: environment,
      platform: stateDir,
    );
    final warnings = [
      if (await ownStore.exists())
        certificateExpiryWithin(
          (await ownStore.loadOrCreate(commonName: 'unused')).certificateDer,
          owner: CertificateExpiry.thisHost,
          now: at,
        ),
      for (final device in devices)
        certificateExpiryWithin(
          device.certificateDer,
          owner: device.name,
          now: at,
        ),
    ];
    for (final warning in warnings) {
      if (warning != null) err.writeln('warning: ${warning.message}');
    }
  }
}

/// One [PairedDevice], as it appears on a `--json` line. Not
/// [JsonRenderer]'s null-omission convention for an *absent* fact (every
/// field here always has a value once a device is paired) — only
/// [PairedDevice.agreedReplicaRoots] is ever empty, and an empty list is
/// itself the fact worth reporting (SPEC §4.4's two-step rule), not
/// something to omit.
Map<String, dynamic> _deviceToJson(PairedDevice device) => {
  'type': 'pairedDevice',
  'name': device.name,
  'deviceId': device.deviceId,
  'agreedReplicaRoots': device.agreedReplicaRoots.toList(),
  'pairedAt': device.pairedAt.toIso8601String(),
  'lastKnownAddress': {
    'host': device.lastKnownAddress.host,
    'port': device.lastKnownAddress.port,
  },
};
