import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:dsync/dsync_core/identity/advertisable_address.dart';
import 'package:dsync/dsync_core/identity/device_identity_store.dart';
import 'package:dsync/dsync_core/identity/enrolment_listener.dart';
import 'package:dsync/dsync_core/identity/enrolment_message.dart';
import 'package:dsync/dsync_core/identity/paired_device_store.dart';
import 'package:dsync/dsync_core/identity/pairing_payload.dart';
import 'package:dsync/dsync_core/models/paired_device.dart';
import 'package:dsync/dsync_core/state_dir.dart';
import 'package:qr/qr.dart' show InputTooLongException;

import '../output/qr_terminal_renderer.dart';
import '../stop_signals.dart';

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
/// **Text on stdout, always; a QR on stderr, when the terminal can show
/// one (task e17997).** SPEC §11.4 keeps stdout reserved for the parseable
/// payload line — `dsync pair accept` and any wrapper script need exactly
/// that line, unchanged, on every run — so the QR is additive on stderr,
/// alongside the rest of this command's human commentary, never a
/// replacement for the text. `qr_terminal_renderer.dart` is the encoder and
/// the half-block terminal renderer (its own doc comment carries the
/// dependency-vs-hand-roll reasoning); [qrTerminalSupported] decides whether
/// this run's terminal can be assumed to render it, and this command prints
/// a stated fallback line instead when it cannot, or when the payload is
/// larger than a QR can carry ([InputTooLongException] — see that
/// renderer's own doc comment for why that is checked at all).
///
/// The phone-to-desktop case a rendered QR unblocks is the Flutter head's:
/// its Pair page reads the symbol with the camera and redeems the same
/// payload a pasted line would (SPEC §4.4). The CLI's own two ends need no
/// camera at all — they exchange the text above — so the symbol is additive
/// on every count, and printing it is never something a pairing depends on.
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
/// **And it waits for an answer before it stores anything (task 23344d).**
/// A redeemed token says somebody saw the payload, not that they are the
/// device the operator meant — SPEC §4.4 says plainly that a leaked payload
/// lets a stranger try. So `EnrolmentListener` hands this command the id of
/// whoever redeemed it, and this command prints it and asks, on stderr and
/// stdin: the operator compares four groups of hex against what the other
/// device shows and answers `y` or `n`. That is the camera-less
/// desktop-to-server case SPEC §4.4 calls primary, done in two terminals.
///
/// The cost, stated rather than hidden: pairing is now two-sided. A
/// `dsync pair show` left running in a terminal nobody is at no longer
/// completes on its own — it holds the connection open until the token's
/// window closes, and then refuses. That is also why this command refuses
/// to start at all when [stdinIsTerminal] says there is nobody behind
/// stdin to answer, rather than binding an endpoint whose one prompt could
/// only ever time out.
///
/// [onError]'s refusal reason is filtered the same way: only a refusal
/// reached *after* the real token was actually redeemed — anything other
/// than [EnrolmentListener]'s own [enrolmentTokenRejectedReason] text —
/// ends the wait. A wrong-token guess, a reused/expired-token retry, or a
/// connection that never got as far as presenting a token (a port scan, a
/// bare TLS probe) is not the enrolment this command is waiting for, and
/// must not cut short a legitimate peer that has not connected yet. The
/// wording of that one refusal is therefore [EnrolmentListener]'s own
/// exported constant rather than a copy of the string, since the Flutter
/// head's pairing window (`lib/app/features/pair_show/`) filters refusals
/// by the same rule.
class PairShowCommand extends Command<int> {
  @override
  final name = 'show';

  @override
  final description =
      'Generate a pairing payload for this device and wait for one other '
      'device to redeem it (SPEC §4.4).';

  /// Which port the payload tells the other device to dial *afterwards* —
  /// this host's `dsync agent --serve` port, not the enrolment listener's.
  /// See [PairingPayload.serviceAddress]: the two are never the same number,
  /// and only this side knows whether its agent serves on the default.
  static const optionServePort = 'serve-port';

  /// This host's own label for whichever device redeems the payload — the
  /// handle `dsync pair grant <name> <path>` and `peer://<name>` address it
  /// by from then on.
  ///
  /// Required, and asked for *here* rather than proposed by the enrolling
  /// device: a name the far end chose is a name whoever won the enrolment
  /// race chose (SPEC §4.4 accepts that a leaked payload lets them try), and
  /// `PairedDeviceStore.add` rejects a name collision outright, so a
  /// squatter could take the name meant for the operator's own device and be
  /// granted a replica root under it later. The operator running this
  /// command already knows what they mean to call their peer. It has no
  /// default for the same reason `dsync pair accept --name` has none:
  /// naming is a deliberate choice, not something to guess at.
  static const optionName = 'name';

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

  /// Whether [err] is a real terminal (task e17997) — the one piece of real
  /// I/O [qrTerminalSupported] needs beyond [environment]'s already-injected
  /// `TERM`, kept as its own overridable function for the same reason
  /// [advertisableAddress] is: a test forces it either way instead of
  /// depending on this process's real streams.
  final bool Function() hasTerminal;

  /// Whether stdin has somebody behind it to answer the confirmation prompt
  /// (task 23344d) — the stdin half of [hasTerminal], injected for the same
  /// reason and checked the same way `InteractivePresenter` checks its own
  /// `isTerminal`: a test process never has a terminal, so a real round
  /// trip could not otherwise reach the prompt at all.
  final bool Function() stdinIsTerminal;

  /// One line of input per prompt. A factory rather than a [Stream] so the
  /// real one — a transform over the process's own `stdin` — is not built
  /// for a run that never gets as far as asking, and is subscribed to
  /// exactly once when it does.
  final Stream<String> Function() confirmationLines;

  PairShowCommand({
    required this.environment,
    required this.platform,
    IOSink? out,
    IOSink? err,
    this.port = 0,
    this.advertisableAddress = preferredAdvertisableAddress,
    this.hasTerminal = stderrHasTerminal,
    this.stdinIsTerminal = _stdinHasTerminal,
    this.confirmationLines = _stdinLines,
  }) : out = out ?? stdout,
       err = err ?? stderr {
    argParser
      ..addOption(
        optionName,
        help:
            'This host\'s own label for the device that redeems this '
            'payload (SPEC §4.4) — local, like a `~/.ssh/config` Host '
            'alias, and what `dsync pair grant` and `peer://` address it '
            'by. Required.',
      )
      ..addOption(
        optionServePort,
        valueHelp: 'port',
        defaultsTo: '${PeerAddress.defaultPort}',
        help:
            "The port this device's `dsync agent --serve` listens on. Goes "
            'into the payload as the address the paired device dials from '
            'then on, so give it here if --serve runs on a non-default '
            'port.',
      );
  }

  @override
  Future<int> run() async {
    if (argResults!.rest.isNotEmpty) {
      usageException('dsync pair show takes no arguments.');
    }
    final peerName = argResults!.option(optionName);
    if (peerName == null || peerName.trim().isEmpty) {
      usageException(
        'dsync pair show needs --name: this host\'s own label for the '
        'device that redeems the payload.',
      );
    }
    final servePort = _parseServePort(argResults!.option(optionServePort));

    // Checked before anything is bound or printed (task 23344d): this
    // command's pairing cannot complete without somebody answering the
    // confirmation prompt, so a run with nothing behind stdin would bind an
    // endpoint, print a payload, and then refuse whoever redeemed it. Say so
    // now instead. SPEC §11.5 fatal — the same bucket `NonInteractiveStdinError`
    // puts interactive review in, for the same reason: never imply consent
    // nobody gave.
    if (!stdinIsTerminal()) {
      err.writeln(
        'dsync pair show: stdin is not a terminal, so there is nobody to '
        'confirm the device that redeems this payload (SPEC §4.4). Run it '
        'from a terminal, or pair the other way round with '
        '`dsync pair accept` on this device.',
      );
      return 3;
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

    // Completed by the expiry timer below — but only while the token is
    // still unredeemed. Once a peer has redeemed it and the prompt is up,
    // "nothing used this code" has stopped being true, and the outcome is
    // whatever the operator answers (or `EnrolmentListener`'s own refusal
    // when they answer nothing); letting the timer win there would print
    // "no device enrolled" over a pairing that was in fact being recorded.
    final expired = Completer<void>();
    var redeemed = false;

    final input = StreamIterator<String>(confirmationLines());
    final listener = await EnrolmentListener.bind(
      InternetAddress.anyIPv4,
      port,
      ownIdentity: identity,
      peerName: peerName,
      token: token,
      tokenExpiresAt: tokenExpiresAt,
      pairedDeviceStore: pairedDeviceStore,
      confirm: (deviceId) {
        redeemed = true;
        return _confirm(deviceId, peerName, input);
      },
      onError: (error, _) {
        if (error is EnrolmentRefusedException &&
            error.reason != enrolmentTokenRejectedReason &&
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
        servicePort: servePort,
        token: token,
      );

      // SPEC §11.4: the payload is machine-parseable data, so it goes to
      // stdout — pipeable and copyable — while every line of commentary
      // below goes to stderr (`agent_command.dart`'s `_serveSocket` gives
      // the same reasoning for its own startup line).
      out.writeln(payload.encode());

      final qrSupported = qrTerminalSupported(
        hasTerminal: hasTerminal(),
        termEnvironmentVariable: environment['TERM'],
      );
      err.writeln(
        'dsync pair show: this device is ${identity.deviceId}. Waiting up '
        'to ${defaultEnrolmentTokenTtl.inMinutes} minutes for one device to '
        'redeem the payload above — paste it into `dsync pair accept` on '
        'the other device${qrSupported ? ', or scan the QR below' : ''}. '
        'Ctrl-C cancels.',
      );

      // Additive, never instead of the stdout line above (SPEC §11.4,
      // task e17997): a terminal detected as unable to render the half-block
      // glyphs faithfully (see [qrTerminalSupported]'s own doc comment), or a
      // payload too large for a QR to carry at all ([InputTooLongException]
      // — see `qr_terminal_renderer.dart`'s own doc comment for why that is
      // even checked), gets a stated fallback line instead of the symbol,
      // never a failed command: the plain-text payload already printed above
      // is enough to keep pairing working either way.
      if (qrSupported) {
        try {
          err
            ..writeln()
            ..writeln(renderPairingQr(payload.encode()))
            ..writeln();
        } on InputTooLongException {
          err.writeln(
            'dsync pair show: this pairing payload is too large to render '
            'as a QR — paste the payload line above into `dsync pair '
            'accept` instead.',
          );
        }
      } else {
        err.writeln(
          'dsync pair show: this terminal is not detected as supporting '
          'the Unicode block characters a QR needs — paste the payload '
          'line above into `dsync pair accept` instead.',
        );
      }

      // Four ways this wait ends, raced against each other. Nothing polls:
      // the listener reports the one enrolment it can ever accept, rather
      // than this re-reading the store to discover what the object in front
      // of it already knows.
      //
      // Each arm is distinguished by the type it yields, which is what lets
      // one `Future.any` carry all four without a flag to sort them out
      // afterwards.
      final expiryTimer = Timer(tokenExpiresAt.difference(DateTime.now()), () {
        if (!redeemed && !expired.isCompleted) expired.complete();
      });
      final Object? outcome;
      try {
        outcome = await Future.any<Object?>([
          listener.enrolled,
          refused.future,
          signals.code,
          expired.future.then((_) => null),
        ]);
      } finally {
        expiryTimer.cancel();
      }

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
      await input.cancel();
    }
  }

  /// SPEC §4.4's out-of-band check, as two terminals (task 23344d): print
  /// the id of whoever redeemed the payload, and wait for a `y` or an `n`.
  ///
  /// The id goes to stderr with the rest of this command's commentary —
  /// stdout stays the parseable payload line and nothing else (SPEC §11.4),
  /// which is what `dsync pair accept` and any wrapper script read.
  ///
  /// An input stream that ends before an answer arrives is a refusal, not
  /// an acceptance: with nobody left to ask, refusing is the only answer
  /// that does not record a device on a decision nobody made — the same
  /// rule `InteractivePresenter` applies when its own input closes.
  /// Anything that is neither `y` nor `n` re-prompts rather than guessing.
  Future<bool> _confirm(
    String deviceId,
    String peerName,
    StreamIterator<String> input,
  ) async {
    err
      ..writeln()
      ..writeln(
        'dsync pair show: a device redeemed the payload and says it is:',
      )
      ..writeln('  $deviceId')
      ..writeln(
        'Check that against the id "$peerName" shows on its own screen — '
        '`dsync pair accept` prints it as it connects. Pair only if every '
        'group matches; if they do not, somebody else got there first '
        '(SPEC §4.4).',
      );

    while (true) {
      err.write('  [y] pair  [n] refuse > ');
      if (!await input.moveNext()) {
        err.writeln();
        return false;
      }
      final answer = input.current.trim().toLowerCase();
      if (answer == 'y') return true;
      if (answer == 'n') return false;
      err.writeln('Not understood: "${input.current}". Enter y or n.');
    }
  }

  /// [optionServePort]'s value as a dialable port. A value that is not one
  /// is a usage error — caught before the listener is bound, the same
  /// bucket `dsync agent --port` puts it in — rather than a
  /// [FormatException] out of [PeerAddress] once a payload is being built.
  int _parseServePort(String? argument) {
    final port = argument == null ? null : int.tryParse(argument);
    if (port == null || port < 1 || port > 65535) {
      usageException(
        '--$optionServePort needs a number from 1 to 65535, not "$argument".',
      );
    }
    return port;
  }

  /// Starts trapping SIGINT/SIGTERM, in the same shape
  /// `AgentCommand._watchStopSignals` does, over the same `watchStopSignals`
  /// (`lib/cli/stop_signals.dart`) — shared since task 7ba6b5 gave it a third
  /// caller (`SyncRunner`) and one host-specific guard worth keeping in one
  /// place.
  ///
  /// `code` completes with the exit code for whichever signal arrives first
  /// (SPEC §11.5 — 130 for SIGINT, 143 for SIGTERM); `cancel` releases the
  /// watches, and the caller owes it on every path.
  ({Future<int> code, Future<void> Function() cancel}) _watchStopSignals() {
    final stopped = Completer<int>();
    final subscription = watchStopSignals().listen((signal) {
      if (!stopped.isCompleted) stopped.complete(signal.exitCode);
    });
    return (code: stopped.future, cancel: subscription.cancel);
  }
}

/// The real [PairShowCommand.stdinIsTerminal].
bool _stdinHasTerminal() => stdin.hasTerminal;

/// The real [PairShowCommand.confirmationLines]: this process's own stdin,
/// one line per element — the same transform `SyncRunner` builds for
/// `InteractivePresenter`.
Stream<String> _stdinLines() =>
    stdin.transform(utf8.decoder).transform(const LineSplitter());
