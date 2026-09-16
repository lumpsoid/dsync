import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:dsync/dsync_core/state_dir.dart';

import 'pair_accept_command.dart';
import 'pair_grant_command.dart';
import 'pair_list_command.dart';
import 'pair_renew_command.dart';
import 'pair_revoke_command.dart';
import 'pair_show_command.dart';

/// `dsync pair` (SPEC §4.4, §11.1, task bc68c7): the CLI surface over the
/// pairing exchange (`lib/dsync_core/identity/pairing_payload.dart`,
/// `enrolment_listener.dart`, `enrolment_client.dart`) and the paired-device
/// store (`lib/dsync_core/identity/paired_device_store.dart`).
///
/// A branch command — see `package:args`' own doc comment on
/// [Command.addSubcommand] — with no `run()` of its own: `dsync pair` alone
/// is a missing-subcommand usage error, reported by `CommandRunner` itself
/// before any of the subcommands below ever runs (SPEC §11.5, "fatal — bad
/// arguments").
///
/// Five subcommands, one file each (matching this directory's existing
/// convention — `sync_command.dart`, `status_command.dart`,
/// `agent_command.dart` are each one command, one file):
/// - [PairShowCommand] — generate a token, bind the enrolment listener, print
///   this device's payload, wait for one enrolment.
/// - [PairAcceptCommand] — the other side: decode a payload, run
///   `enrolWithPeer`.
/// - [PairListCommand] — the paired devices, human or `--json` (SPEC §11.4).
/// - [PairRevokeCommand] — remove one.
/// - [PairGrantCommand] — authorize a paired device for a replica root
///   (SPEC §4.4: "Pairing a device and authorizing it for a path are
///   consequently always two steps; the second is not yet named as a
///   command (`bc68c7`'s ... to expose)" — this is that command).
///
/// [environment] and [platform] are threaded through to every subcommand
/// exactly as `DsyncCommandRunner` threads them into `SyncRunner` — each
/// subcommand resolves its own `DeviceIdentityStore`/`PairedDeviceStore` from
/// them rather than from `Platform.environment`/`Platform.operatingSystem`
/// directly, so a test can point a pairing operation at an isolated
/// `XDG_STATE_HOME` and a chosen platform (the same convention
/// `PairedDeviceStore.forStateDir`/`DeviceIdentityStore.forStateDir` already
/// support). [out]/[err] default to the real [stdout]/[stderr] and are
/// threaded the same way, for the same reason `JsonRenderer` takes them as
/// constructor parameters rather than reaching for the globals directly: a
/// test reads what a subcommand printed from an in-memory sink instead of
/// capturing the real process streams.
class PairCommand extends Command<int> {
  @override
  final name = 'pair';

  @override
  final description =
      'Pair devices for the authenticated network transport, and authorize '
      'a paired device for a replica root (SPEC §4.4).';

  PairCommand({
    required Map<String, String> environment,
    required StateDirPlatform platform,
    IOSink? out,
    IOSink? err,
  }) {
    addSubcommand(
      PairShowCommand(
        environment: environment,
        platform: platform,
        out: out,
        err: err,
      ),
    );
    addSubcommand(
      PairAcceptCommand(
        environment: environment,
        platform: platform,
        out: out,
        err: err,
      ),
    );
    addSubcommand(
      PairListCommand(
        environment: environment,
        platform: platform,
        out: out,
        err: err,
      ),
    );
    addSubcommand(
      PairRevokeCommand(
        environment: environment,
        platform: platform,
        out: out,
        err: err,
      ),
    );
    addSubcommand(
      PairRenewCommand(
        environment: environment,
        platform: platform,
        out: out,
        err: err,
      ),
    );
    addSubcommand(
      PairGrantCommand(
        environment: environment,
        platform: platform,
        out: out,
        err: err,
      ),
    );
  }
}
