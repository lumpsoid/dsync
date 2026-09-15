import 'dart:async';
import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:dsync/dsync_core/identity/device_identity_store.dart';
import 'package:dsync/dsync_core/identity/enrolment_listener.dart';
import 'package:dsync/dsync_core/identity/enrolment_message.dart';
import 'package:dsync/dsync_core/identity/paired_device_store.dart';
import 'package:dsync/dsync_core/identity/pairing_payload.dart';
import 'package:dsync/dsync_core/models/paired_device.dart';
import 'package:dsync/dsync_core/state_dir.dart';

import '../agents/local_addresses.dart';
import '../exit_code.dart';

/// `dsync pair show` (SPEC §4.4, §11.1, task bc68c7): generate a token, bind
/// the enrolment listener, print this device's payload, and wait for one
/// enrolment.
///
/// **This is what makes "off by default and open only for the duration of
/// one pairing operation" (SPEC §4.4) true in practice.** The enrolment
/// endpoint (`EnrolmentListener`) exists only between the `bind` call below
/// and [run] returning — never before this command is invoked, never after
/// it ends, on every path including a signal (the `try`/`finally` around
/// [_watchStopSignals] below, the same shape `AgentCommand._serveSocket`
/// uses for the same reason on the replica listener).
///
/// **Text only — no QR rendering here.** SPEC §4.4 names a QR image as one
/// way to carry this payload, and a terminal *could* render one as block
/// characters. This command deliberately does not:
/// - A QR encoder is either a new pinned dependency (SPEC §3, which this
///   project has stayed conservative about — see
///   `self_signed_certificate.dart`'s own ~170-line-over-`basic_utils`
///   reasoning for the same kind of tradeoff) or a few hundred lines of
///   Reed-Solomon this task has no reason to own alongside the CLI wiring
///   itself.
/// - SPEC §4.4 calls text the *primary* path for the desktop-to-server case
///   — neither end has a camera — which is exactly the case a CLI serves.
///   Deferring the image is not deferring the common case.
/// - The phone-to-desktop case that would want a rendered QR also needs the
///   Flutter head, which is a skeleton today (SPEC §16). Deferring the
///   rendering blocks nothing that currently exists.
///
/// This leaves phone-to-desktop pairing genuinely unreachable from the CLI
/// alone — worth saying plainly rather than leaving it looking complete.
/// Follow-up filed: task e17997 ("cli: render dsync pair's payload as a QR
/// in the terminal").
///
/// **How this knows an enrolment happened.** [EnrolmentListener.enrolled]
/// completes with the device it recorded — the listener saying so, rather
/// than this command re-reading [PairedDeviceStore] on a timer to discover
/// what the object in front of it already knew. That signal can be a single
/// [Future] rather than a stream because the listener's token gate is
/// single-use and synchronous (its own class doc comment): exactly one
/// enrolment can ever happen through one listener, by construction.
///
/// It completes only on success, which is the property this command needs —
/// a stranger's failed probe must not end a window a legitimate peer is
/// still walking across the room to use.
///
/// [onError]'s refusal reason is filtered the same way: only a refusal
/// reached *after* the real token was actually redeemed — anything other
/// than [EnrolmentListener]'s own `'Enrolment token rejected.'` text —
/// ends the wait. A wrong-token guess, a reused/expired-token retry, or a
/// connection that never got as far as presenting a token (a port scan, a
/// bare TLS probe) is not the enrolment this command is waiting for, and
/// must not cut short a legitimate peer that has not connected yet. This
/// does couple to `EnrolmentListener`'s exact wording for that one message;
/// documented here rather than silently relied on, since it is the price of
/// not adding a distinguishing field to a class this task was told to leave
/// alone.
class PairShowCommand extends Command<int> {
  @override
  final name = 'show';

  @override
  final description =
      'Generate a pairing payload for this device and wait for one other '
      'device to redeem it (SPEC §4.4).';

  /// The only refusal reason [EnrolmentListener._redeemToken] itself
  /// produces (`enrolment_listener.dart`) — every other [EnrolmentRefused]
  /// reason is only reachable once the real token has already been
  /// redeemed. See this class's doc comment.
  static const _tokenRejectedReason = 'Enrolment token rejected.';

  final Map<String, String> environment;
  final StateDirPlatform platform;
  final IOSink out;
  final IOSink err;

  /// Where to bind the enrolment listener. `0` (the default) asks the OS
  /// for an ephemeral port — this listener is a one-shot, short-lived thing
  /// distinct from SPEC §4.4's fixed 28771 (which is the *paired-replica*
  /// network listener's port, not this one), so there is no fixed value to
  /// coordinate and no reason to risk colliding with anything already bound.
  /// The real port is read back off the bound socket and carried inside the
  /// payload itself, the same way the tests in `enrolment_test.dart` do.
  final int port;

  /// This machine's own best-effort advertisable address (SPEC §4.4's
  /// address hint) — see [preferredAdvertisableAddress]'s own doc comment.
  /// Overridable so a test can pin it to `127.0.0.1` rather than depend on
  /// this machine's real network interfaces.
  final Future<String?> Function() advertisableAddress;

  PairShowCommand({
    required this.environment,
    required this.platform,
    IOSink? out,
    IOSink? err,
    this.port = 0,
    this.advertisableAddress = preferredAdvertisableAddress,
  }) : out = out ?? stdout,
       err = err ?? stderr;

  @override
  Future<int> run() async {
    if (argResults!.rest.isNotEmpty) {
      usageException('dsync pair show takes no arguments.');
    }

    final identity = await DeviceIdentityStore.forStateDir(
      environment: environment,
      platform: platform,
    ).loadOrCreate(commonName: Platform.localHostname);
    final pairedDeviceStore = PairedDeviceStore.forStateDir(
      environment: environment,
      platform: platform,
    );

    final token = generateEnrolmentToken();
    final tokenExpiresAt = DateTime.now().add(defaultEnrolmentTokenTtl);

    // Completed by `onError` below when a refusal happened *after* the real
    // token was redeemed — see the class doc comment. A `Completer` so it can
    // end the wait below directly: once the token is burned, no later
    // connection can succeed, so continuing to wait out the full window
    // would only make the operator sit through a timeout for an answer that
    // is already known. `EnrolmentListener`'s redemption gate is synchronous
    // and single-use, so at most one connection can ever complete this, but
    // the guard stays because a `Completer` completed twice throws.
    final refused = Completer<String>();

    final listener = await EnrolmentListener.bind(
      InternetAddress.anyIPv4,
      port,
      ownIdentity: identity,
      token: token,
      tokenExpiresAt: tokenExpiresAt,
      pairedDeviceStore: pairedDeviceStore,
      onError: (error, _) {
        if (error is EnrolmentRefusedException &&
            error.reason != _tokenRejectedReason &&
            !refused.isCompleted) {
          refused.complete(error.reason);
        }
      },
    );

    // Watched *before* anything is printed, for the same reason
    // `AgentCommand._serveSocket` watches before binding: a signal that
    // lands before the trap is installed kills this process outright, which
    // would leave the listener bound with no `finally` left to run.
    final signals = _watchStopSignals();
    try {
      final boundPort = int.parse(
        listener.address.substring(listener.address.lastIndexOf(':') + 1),
      );
      final host =
          await advertisableAddress() ?? InternetAddress.loopbackIPv4.address;
      final payload = PairingPayload(
        certificateDer: identity.certificateDer,
        address: PeerAddress(host: host, port: boundPort),
        token: token,
      );

      // SPEC §11.4: the payload is machine-parseable data, so it goes to
      // stdout — pipeable and copyable — while every line of commentary
      // below goes to stderr (`agent_command.dart`'s `_serveSocket` gives
      // the same reasoning for its own startup line).
      out.writeln(payload.encode());
      err.writeln(
        'dsync pair show: this device is ${identity.deviceId}. Waiting up '
        'to ${defaultEnrolmentTokenTtl.inMinutes} minutes for one device to '
        'redeem the payload above — paste it into `dsync pair accept` on '
        'the other device (no QR rendering yet; see task e17997). '
        'Ctrl-C cancels.',
      );

      // Four ways this wait ends, raced against each other. Nothing polls:
      // the listener reports the one enrolment it can ever accept, rather
      // than this re-reading the store to discover what the object in front
      // of it already knows.
      //
      // Each arm is distinguished by the type it yields, which is what lets
      // one `Future.any` carry all four without a flag to sort them out
      // afterwards.
      final outcome = await Future.any<Object?>([
        listener.enrolled,
        refused.future,
        signals.code,
        Future<void>.delayed(tokenExpiresAt.difference(DateTime.now()))
            .then((_) => null),
      ]);

      if (outcome is PairedDevice) {
        err.writeln(
          'dsync pair show: paired with "${outcome.name}" '
          '(${outcome.deviceId}). Grant it a replica root with '
          '`dsync pair grant "${outcome.name}" <path>` before it can '
          'reach anything (SPEC §4.4).',
        );
        return 0;
      }
      if (outcome is String) {
        err.writeln('dsync pair show: enrolment refused: $outcome');
        return 3; // SPEC §11.5: fatal — a refused enrolment.
      }
      if (outcome is int) return outcome; // SIGINT/SIGTERM: 130/143.

      err.writeln(
        'dsync pair show: no device enrolled before the token expired. '
        'Run `dsync pair show` again for a fresh one.',
      );
      return 3; // SPEC §11.5: fatal — no peer reached in time.
    } finally {
      // Every path, including a signal: this is the property SPEC §4.4
      // needs true in practice (see the class doc comment).
      await listener.close();
      await signals.cancel();
    }
  }

  /// Starts trapping SIGINT/SIGTERM, in the same shape
  /// `AgentCommand._watchStopSignals` does — kept as its own small copy
  /// here rather than shared, since the two commands otherwise depend on
  /// nothing of each other's and six lines of duplication is cheaper than a
  /// new shared module for one caller on each side.
  ///
  /// `code` completes with the exit code for whichever signal arrives first
  /// (SPEC §11.5 — 130 for SIGINT, 143 for SIGTERM); `cancel` releases both
  /// watches, and the caller owes it on every path.
  ({Future<int> code, Future<void> Function() cancel}) _watchStopSignals() {
    final stopped = Completer<int>();
    void stop(int exitCode) {
      if (!stopped.isCompleted) stopped.complete(exitCode);
    }

    final subscriptions = [
      ProcessSignal.sigint.watch().listen((_) => stop(sigintExitCode)),
      ProcessSignal.sigterm.watch().listen((_) => stop(sigtermExitCode)),
    ];
    return (
      code: stopped.future,
      cancel: () async {
        for (final subscription in subscriptions) {
          await subscription.cancel();
        }
      },
    );
  }
}
