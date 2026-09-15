import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:dsync/dsync_core/identity/device_id.dart';
import 'package:dsync/dsync_core/identity/device_identity_store.dart';
import 'package:dsync/dsync_core/identity/enrolment_client.dart';
import 'package:dsync/dsync_core/identity/enrolment_message.dart';
import 'package:dsync/dsync_core/identity/paired_device_store.dart';
import 'package:dsync/dsync_core/identity/pairing_payload.dart';
import 'package:dsync/dsync_core/state_dir.dart';

/// `dsync pair accept <payload>` (SPEC §4.4, §11.1, task bc68c7) — the other
/// side of `dsync pair show`: decode the pasted or scanned payload, run
/// `enrolWithPeer`, report which device was paired.
///
/// Text only, by design (task bc68c7's own deliberate deferral, see
/// `pair_show_command.dart`'s doc comment for the full reasoning): the
/// payload argument is whatever line `dsync pair show` printed to stdout, or
/// whatever a future QR reader decodes back into the same text — this
/// command does not know or care which.
///
/// **Why a refused enrolment names the specific refusal, unlike
/// `AgentListener`'s deliberately non-disclosing one.** `AgentServer`'s
/// `hello` refusal (SPEC §4.4, "The refusal does not confirm what it
/// refused") hides *why* on purpose, because the peer asking might be a
/// stranger probing what exists on the other end. The situation here is the
/// opposite one: whoever reads this command's stderr is the operator
/// running `dsync pair accept` themselves, on a device they already control,
/// trying to pair it with another device they also already control. There is
/// no adversary on the other end of *this* message — it never leaves this
/// process — so collapsing "wrong token", "expired token", "already-used
/// token", "name collision" and "malformed certificate" into one generic
/// "pairing failed" would only cost the operator time re-deriving which of
/// those five different fixes (get a fresh payload, retry within the window,
/// ask `dsync pair show` to run again, pick a different `--name`, check the
/// payload was copied correctly) actually applies. `EnrolmentRefused.reason`
/// (`enrolment_message.dart`) already carries that distinction end to end —
/// this command's job is only to not throw it away.
class PairAcceptCommand extends Command<int> {
  @override
  final name = 'accept';

  @override
  final description =
      'Accept a pairing payload from `dsync pair show` (SPEC §4.4) and '
      'record the enrolling device.';

  static const _optionName = 'name';
  static const _optionAs = 'as';

  final Map<String, String> environment;
  final StateDirPlatform platform;
  final IOSink out;
  final IOSink err;

  PairAcceptCommand({
    required this.environment,
    required this.platform,
    IOSink? out,
    IOSink? err,
  }) : out = out ?? stdout,
       err = err ?? stderr {
    argParser
      ..addOption(
        _optionName,
        help:
            'This host\'s own label for the device being paired (SPEC '
            '§4.4) — local, like a `~/.ssh/config` Host alias. Required: '
            'naming is a deliberate operator choice, not a default this '
            'command should guess at.',
      )
      ..addOption(
        _optionAs,
        help:
            'What to call this device on the far end\'s own paired-device '
            'list. Defaults to this host\'s hostname.',
      );
  }

  @override
  Future<int> run() async {
    final results = argResults!;
    final rest = results.rest;
    if (rest.length != 1) {
      usageException(
        'dsync pair accept needs exactly one argument: the payload printed '
        'by `dsync pair show` on the other device.',
      );
    }
    final localName = results.option(_optionName);
    if (localName == null || localName.trim().isEmpty) {
      usageException(
        'dsync pair accept needs --name: this host\'s own label for the '
        'device being paired.',
      );
    }
    final proposedName = results.option(_optionAs) ?? Platform.localHostname;

    final PairingPayload payload;
    try {
      payload = PairingPayload.decode(rest.single);
    } on FormatException catch (e) {
      // SPEC §11.5: fatal — bad arguments. Caught here rather than left to
      // `runDsyncCli`'s catch-all so the message reads as this command's own
      // usage error (with the usage block printed alongside it) rather than
      // a bare stringified exception.
      usageException('dsync pair accept: $e');
    }

    final identity = await DeviceIdentityStore.forStateDir(
      environment: environment,
      platform: platform,
    ).loadOrCreate(commonName: Platform.localHostname);
    final pairedDeviceStore = PairedDeviceStore.forStateDir(
      environment: environment,
      platform: platform,
    );

    try {
      await enrolWithPeer(
        payload: payload,
        ownIdentity: identity,
        proposedName: proposedName,
        localName: localName,
        pairedDeviceStore: pairedDeviceStore,
      );
    } on EnrolmentRefusedException catch (e) {
      err.writeln('dsync pair accept: enrolment refused: ${e.reason}');
      return 3;
    } on HandshakeException catch (e) {
      err.writeln(
        'dsync pair accept: could not verify '
        '${payload.address.host}:${payload.address.port} as the device '
        'this payload names ($e). Either the payload is stale, or it names '
        'a different device than the one that answered — get a fresh '
        'payload from `dsync pair show`.',
      );
      return 3;
    } on SocketException catch (e) {
      err.writeln(
        'dsync pair accept: could not reach '
        '${payload.address.host}:${payload.address.port}: $e',
      );
      return 3;
    } on PairedDeviceCollisionException catch (e) {
      // The far end already accepted and recorded us (SPEC §4.4) before this
      // side's own, purely local record of *it* failed — worth saying
      // plainly, since the two sides are now out of sync: the far end trusts
      // this device, and this side does not yet trust it back.
      err.writeln(
        'dsync pair accept: the far end accepted this pairing, but it '
        'could not be recorded here: $e',
      );
      return 3;
    }

    final deviceId = deviceIdFromCertificateDer(payload.certificateDer);
    out.writeln('paired: "$localName" ($deviceId)');
    return 0;
  }
}
