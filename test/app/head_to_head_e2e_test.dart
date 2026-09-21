/// Two Flutter heads, no CLI anywhere: pair them against each other, share
/// a folder, serve from one and run from the other, then turn the pair
/// around and do it the other way (SPEC §2, §4.4).
///
/// This is the case the Serve feature exists for. Before it, the head was a
/// replica *client* — it dialled `dsync agent --serve` on a desktop and was
/// never dialled — so a desktop could not start a run against a phone and
/// two phones could not sync at all. Everything below runs through the
/// head's own controllers: `PairShowController` and `PairController` for
/// the pairing, `AppController.grantRoot` for the share, `ServeController`
/// for the answering side and `SyncRunController` with the real `dialPeer`
/// for the dialling one. The only things faked are the wakelock, which no
/// test binding answers, and this machine's advertisable address.
///
/// What it proves that `serve_controller_test.dart` does not: that a
/// listener the head binds actually accepts a head that dials it, that the
/// grant one head's Shared folders page writes is the grant the other
/// head's `hello` is checked against, and that the symmetry is real rather
/// than assumed — step six runs the whole thing backwards.
library;

import 'dart:async';
import 'dart:io';

import 'package:dsync/app/app_controller.dart';
import 'package:dsync/app/app_paths.dart';
import 'package:dsync/app/features/pair/pair_controller.dart';
import 'package:dsync/app/features/pair/pair_view_state.dart';
import 'package:dsync/app/features/pair_show/pair_show_controller.dart';
import 'package:dsync/app/features/pair_show/pair_show_view_state.dart';
import 'package:dsync/app/features/run/replica_connector.dart';
import 'package:dsync/app/features/run/run_controller.dart';
import 'package:dsync/app/features/run/run_view_state.dart';
import 'package:dsync/app/features/serve/serve_controller.dart';
import 'package:dsync/app/features/serve/serve_view_state.dart';
import 'package:dsync/app/features/run_setup/run_setup_controller.dart';
import 'package:dsync/app/run_request.dart';
import 'package:dsync/dsync_core/agent/agent_listener.dart';
import 'package:dsync/dsync_core/identity/enrolment_client.dart';
import 'package:dsync/dsync_core/models/paired_device.dart';
import 'package:flutter/foundation.dart';
import 'package:test/test.dart';

import '../support/fake_screen_wake.dart';

/// How long any one asynchronous step gets — a pairing exchange, a whole
/// run — before this file fails with a message rather than the suite timing
/// out around it. Same figure as the other two e2e files.
const _deadline = Duration(seconds: 60);

/// One head, as this file drives it: its own state directory, its own
/// replica root, and the serve controller that makes it answerable.
class _Head {
  _Head({
    required this.app,
    required this.root,
    required this.serve,
    required this.name,
  });

  final AppController app;
  final Directory root;
  final ServeController serve;

  /// What the *other* head calls this one — the name a grant and a run
  /// address it by over there.
  final String name;
}

void main() {
  late Directory tempDir;
  late _Head a;
  late _Head b;

  _Head head(String name, String stateDir, Directory root) {
    final app = AppController(
      () async => AppPaths(stateDir),
      now: DateTime.now,
    );
    return _Head(
      app: app,
      root: root,
      name: name,
      serve: ServeController(
        app,
        bind: AgentListener.bindSecure,
        bindAddress: () async => InternetAddress.loopbackIPv4,
        environment: const {},
        screenWake: FakeScreenWake(),
        // Ephemeral, for the reason `ServeController.port` documents: 28771
        // is fixed in production and cannot be assumed free here.
        port: 0,
      ),
    );
  }

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('dsync_head_to_head_');
    a = head(
      'a',
      '${tempDir.path}/a-state',
      await Directory('${tempDir.path}/a-root').create(recursive: true),
    );
    b = head(
      'b',
      '${tempDir.path}/b-state',
      await Directory('${tempDir.path}/b-root').create(recursive: true),
    );
  });

  tearDown(() async {
    a.serve.dispose();
    b.serve.dispose();
    a.app.dispose();
    b.app.dispose();
    await tempDir.delete(recursive: true);
  });

  /// Pairs [scanner] into [shower] the way two people with two phones would
  /// do it: [shower] opens its own code page, [scanner] pastes the line,
  /// and the operator at [shower] confirms the id.
  ///
  /// [shower] must already be serving, because the payload it shows carries
  /// the port the other side will dial *afterwards* — which is exactly what
  /// `PairShowController.servicePort` is for, and why this test pairs after
  /// binding rather than before.
  Future<void> pair(_Head shower, _Head scanner) async {
    final show = PairShowController(
      shower.app,
      bind: bindEnrolmentListenerOnThisDevice,
      bindAddress: () async => InternetAddress.loopbackIPv4,
      advertisableAddress: () async => '127.0.0.1',
      servicePort: shower.serve.boundPort!,
    );
    addTearDown(show.dispose);
    // Not awaited: `show` runs until the token is redeemed or the window
    // closes, and the other head's half is what redeems it.
    final showing = show.show(peerName: scanner.name);

    final waiting = await _await<PairShowWaiting>(
      show.state,
      () => show.state.status,
      what: 'the code to be shown',
    );

    final scan = PairController(scanner.app, enrol: enrolWithPeer);
    addTearDown(scan.dispose);
    scan.codeEntered(waiting.offer.payloadLine);
    final submitted = scan.submitPayload(localName: shower.name);

    // The operator at the showing side compares the ids and says yes. The
    // confirmation is `enrolment_test.dart`'s subject; here it is a step to
    // get past.
    final confirming = await _await<PairShowConfirming>(
      show.state,
      () => show.state.status,
      what: 'the confirmation prompt',
    );
    expect(confirming.deviceId, isNotEmpty);
    show.answerConfirmation(confirmed: true);

    await submitted.timeout(_deadline);
    await showing.timeout(_deadline);
    expect(
      scan.state.outcome,
      isA<PairSucceeded>(),
      reason: 'pairing failed: ${scan.state.outcome}',
    );
    expect(show.state.status, isA<PairShowPaired>());
  }

  /// Drives one run on [from] to its end through the real `dialPeer`,
  /// answering the conflict sheet with "accept all" the moment it opens —
  /// the same shape `pair_then_sync_e2e_test.dart` uses, and for the same
  /// reason: `start` does not return until the sheet is answered.
  Future<SyncRunPhase> run(
    _Head from, {
    required _Head to,
    required String remoteRootPath,
    PeerAddress? addressOverride,
  }) async {
    final deviceId = (await (await from.app.pairedDevices).byName(to.name))!
        .deviceId;
    final controller = SyncRunController(
      from.app,
      dial: dialPeer,
      screenWake: FakeScreenWake(),
    );
    addTearDown(controller.dispose);
    final started = controller.start(
      RunRequest(
        localRootPath: from.root.path,
        deviceName: to.name,
        peerDeviceId: deviceId,
        remoteRootPath: remoteRootPath,
        addressOverride: addressOverride,
        jobs: 2,
        dryRun: false,
      ),
    );
    final until = DateTime.now().add(_deadline);
    while (true) {
      final phase = controller.state.phase;
      if (phase is SyncRunAwaitingDecisions) {
        controller.acceptAll();
        break;
      }
      if (phase is SyncRunFinished ||
          phase is SyncRunFailed ||
          phase is SyncRunStopped) {
        break;
      }
      if (DateTime.now().isAfter(until)) {
        fail(
          'run never reached the sheet or an end; still $phase. '
          '${to.name} said: ${to.serve.state.sessions}',
        );
      }
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    await started.timeout(_deadline);
    return controller.state.phase;
  }

  /// Where the other head is actually answering. The pairing cached
  /// [PeerAddress.defaultPort] for whichever side did not show the payload
  /// (`EnrolmentListener` deliberately records the default rather than the
  /// enrolment socket's ephemeral source port), so the reversed direction
  /// re-enters the address by hand — SPEC §4.4's own escape hatch, and the
  /// thing a user does when a cached address stops answering.
  PeerAddress servingAt(_Head head) =>
      PeerAddress(host: '127.0.0.1', port: head.serve.boundPort!);

  test('a folder shared by one head syncs to the other, which dialled it '
      '(SPEC §2, §4.4)', () async {
    await b.serve.start();
    expect(b.serve.state.status, isA<ServeListening>());
    await pair(b, a);
    await b.app.grantRoot(
      (await (await b.app.pairedDevices).byName('a'))!.deviceId,
      b.root.path,
    );

    await File('${a.root.path}/from-a.txt').writeAsString('from a');
    await Directory('${a.root.path}/deep').create();
    await File('${a.root.path}/deep/nested.txt').writeAsString('nested');
    await File('${b.root.path}/from-b.txt').writeAsString('from b');

    final phase = await run(a, to: b, remoteRootPath: b.root.path);

    expect(
      phase,
      isA<SyncRunFinished>(),
      reason:
          '${phase is SyncRunFailed ? phase.message : phase}; '
          'b said: ${b.serve.state.sessions}',
    );
    expect((phase as SyncRunFinished).applied, 3);
    expect(phase.failed, 0);
    expect(await File('${b.root.path}/from-a.txt').readAsString(), 'from a');
    expect(
      await File('${b.root.path}/deep/nested.txt').readAsString(),
      'nested',
    );
    expect(await File('${a.root.path}/from-b.txt').readAsString(), 'from b');
    // The serving head saw the session it served, and refused nothing.
    expect(
      b.serve.state.sessions.where((line) => line.contains('Serving')),
      hasLength(1),
    );
    expect(
      b.serve.state.sessions.where((line) => line.contains('Refused')),
      isEmpty,
    );
  });

  test('a root the serving head never shared is refused, and nothing is '
      'written (SPEC §4.4)', () async {
    await b.serve.start();
    await pair(b, a);
    await b.app.grantRoot(
      (await (await b.app.pairedDevices).byName('a'))!.deviceId,
      b.root.path,
    );
    final other = await Directory('${tempDir.path}/b-other').create();
    await File('${a.root.path}/from-a.txt').writeAsString('from a');

    final phase = await run(a, to: b, remoteRootPath: other.path);

    // The handshake succeeds — these two *are* paired — and the `hello` is
    // what is refused, in-band, as the line the Run page renders. Its
    // wording says nothing about whether the folder exists.
    expect(phase, isA<SyncRunFailed>());
    expect(
      (phase as SyncRunFailed).message,
      remoteRootNotGrantedMessage(deviceName: 'b', remoteRoot: other.path),
    );
    expect(await other.list().toList(), isEmpty);
  });

  test('a pairing the serving head revoked is refused at the handshake '
      '(SPEC §4.4)', () async {
    await b.serve.start();
    await pair(b, a);
    final deviceId = (await (await b.app.pairedDevices).byName('a'))!.deviceId;
    await b.app.grantRoot(deviceId, b.root.path);
    await b.app.revoke(deviceId);
    await File('${a.root.path}/from-a.txt').writeAsString('from a');

    final phase = await run(a, to: b, remoteRootPath: b.root.path);

    // A still trusts B, but A's certificate is no longer a trust anchor
    // over there, so the handshake fails before any frame is exchanged.
    expect(phase, isA<SyncRunFailed>());
    expect(
      (phase as SyncRunFailed).message,
      allOf(startsWith('Could not reach "b" at'), contains('by hand')),
    );
    // B's store is empty again, so BoringSSL has no anchors at all — the
    // listener says so in its own words rather than leaving the operator
    // with an opaque verification failure.
    expect(
      b.serve.state.sessions.where((line) => line.contains('Refused:')),
      isNotEmpty,
      reason: 'b said: ${b.serve.state.sessions}',
    );
    expect(await b.root.list().toList(), isEmpty);
  });

  test('the same two heads sync the other way round, with the roles '
      'swapped (SPEC §4.4)', () async {
    await b.serve.start();
    await pair(b, a);
    await b.app.grantRoot(
      (await (await b.app.pairedDevices).byName('a'))!.deviceId,
      b.root.path,
    );
    await File('${a.root.path}/from-a.txt').writeAsString('from a');
    expect(
      await run(a, to: b, remoteRootPath: b.root.path),
      isA<SyncRunFinished>(),
    );

    // Now turn it around: a answers, b dials. Nothing about the pairing
    // changes — a grant is one-sided, so a has to share its own root
    // before b may reach it, and a's address has to be re-entered because
    // the enrolment recorded the default port for it.
    await b.serve.stop();
    await a.serve.start();
    await a.app.grantRoot(
      (await (await a.app.pairedDevices).byName('b'))!.deviceId,
      a.root.path,
    );
    await File('${b.root.path}/from-b-later.txt').writeAsString('later');

    final phase = await run(
      b,
      to: a,
      remoteRootPath: a.root.path,
      addressOverride: servingAt(a),
    );

    expect(
      phase,
      isA<SyncRunFinished>(),
      reason:
          '${phase is SyncRunFailed ? phase.message : phase}; '
          'a said: ${a.serve.state.sessions}',
    );
    expect(
      await File('${a.root.path}/from-b-later.txt').readAsString(),
      'later',
    );
  });
}

/// Waits for [read] to be a [T], listening to [notifier] rather than
/// polling: both controllers here write their outcome into a
/// `ChangeNotifier` and the step this file wants is one of several the
/// window passes through.
Future<T> _await<T>(
  Listenable notifier,
  Object? Function() read, {
  required String what,
}) async {
  final found = Completer<T>();
  void check() {
    final value = read();
    if (value is T && !found.isCompleted) found.complete(value);
  }

  notifier.addListener(check);
  check();
  try {
    return await found.future.timeout(
      _deadline,
      onTimeout: () => fail('timed out waiting for $what'),
    );
  } finally {
    notifier.removeListener(check);
  }
}
