/// The head's own headline case, end to end: pair against a real
/// `EnrolmentListener`, then sync against a real `AgentListener.bindSecure`,
/// both over loopback TLS, both in this process (SPEC §2, §4.4).
///
/// This is to the Flutter head what `test/cli/run/peer_e2e_test.dart` and
/// `test/cli/run/pair_show_accept_e2e_test.dart` are to the CLI — with the
/// difference that both ends run in-process, as the pairing test does:
/// nothing here needs the far side to outlive a command, so a child process
/// would buy only the machinery of one. The head's side is exactly what
/// its pages call — `PairController.codeEntered` then `submitPayload`,
/// with the real `enrolWithPeer`, then
/// `SyncRunController.start` with the real `dialPeer`
/// — and the desktop's side is the two `core` listeners the CLI wraps, over
/// their own identity and paired-device store in a second state directory.
///
/// What it proves that the feature tests in `features/` do not: that the
/// seams every one of them fakes (`EnrolWithPeer`, `DialPeer`) are wired to
/// something that actually reaches a socket, that the store the Pair
/// feature writes is the store the Run feature dials from, that the address
/// a user re-enters by hand (SPEC §4.4) is honoured and cached, and that
/// the two refusals a user will actually hit — a root the desktop never
/// granted, a pairing the desktop revoked — arrive as the rendered lines
/// the Run page shows rather than as a hang or a throw.
library;

import 'dart:io';

import 'package:dsync/app/app_controller.dart';
import 'package:dsync/app/app_paths.dart';
import 'package:dsync/app/features/pair/pair_code.dart';
import 'package:dsync/app/features/pair/pair_controller.dart';
import 'package:dsync/app/features/pair/pair_view_state.dart';
import 'package:dsync/app/features/run/replica_connector.dart';
import 'package:dsync/app/features/run/run_controller.dart';
import 'package:dsync/app/features/run/run_view_state.dart';
import 'package:dsync/app/features/run_setup/run_setup_controller.dart';
import 'package:dsync/app/run_request.dart';
import 'package:dsync/dsync_core/agent/agent.dart';
import 'package:dsync/dsync_core/agent/agent_listener.dart';
import 'package:dsync/dsync_core/agent/local_agent.dart';
import 'package:dsync/dsync_core/archive/jsonl_archive_store.dart';
import 'package:dsync/dsync_core/identity/device_id.dart';
import 'package:dsync/dsync_core/identity/enrolment_client.dart';
import 'package:dsync/dsync_core/identity/enrolment_listener.dart';
import 'package:dsync/dsync_core/identity/paired_device_store.dart';
import 'package:dsync/dsync_core/identity/pairing_payload.dart';
import 'package:dsync/dsync_core/identity/self_signed_certificate.dart';
import 'package:dsync/dsync_core/lock/replica_lock.dart';
import 'package:dsync/dsync_core/models/archive.dart';
import 'package:dsync/dsync_core/models/device_identity.dart';
import 'package:dsync/dsync_core/models/paired_device.dart';
import 'package:dsync/dsync_core/models/replica_spec.dart';
import 'package:test/test.dart';

import '../support/fake_screen_wake.dart';

/// How long any one asynchronous step gets — the enrolment exchange, a
/// whole run — before the test fails with a message rather than the suite
/// timing out around it. Same figure as the CLI's peer e2e.
const _startupDeadline = Duration(seconds: 60);

void main() {
  late Directory tempDir;
  late AppController app;
  late Directory localRoot;
  late Directory remoteRoot;
  late DeviceIdentity desktopIdentity;
  late PairedDeviceStore desktopStore;
  late String desktopStateDir;
  late List<Object> desktopSessionErrors;
  late AgentListener agent;
  late int agentPort;
  late int enrolmentPort;
  late DeviceIdentity phoneIdentity;
  late PairingPayload pairingPayload;
  late PairController pair;
  late EnrolmentListener enrolment;

  setUpAll(() {
    // One key pair for the desktop across every test: the identity is not
    // what any case is about, and generating one is the slow part.
    desktopIdentity = generateDeviceIdentity(commonName: 'desktop');
  });

  /// The desktop's side `b`, built the way `agent_command.dart`'s
  /// `_buildAgent` builds it from the `hello`'s spec: a `LocalAgent` over
  /// the root the head named, keyed by the profile id the head sent, in the
  /// desktop's own state directory. Only ever reached through
  /// `AgentListener`'s own `pair grant` check.
  Agent desktopAgent(ReplicaSpec spec) => LocalAgent(
    rootPath: spec.rootPath,
    archiveStore: JsonlArchiveStore(
      File('$desktopStateDir/${spec.profileId}-b.jsonl'),
      ArchiveHeader(
        schemaVersion: 1,
        profileId: spec.profileId,
        rootPath: spec.rootPath,
      ),
    ),
    replicaLock: ReplicaLock(File('$desktopStateDir/${spec.profileId}-b.lock')),
  );

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('dsync_app_e2e_');
    // Two independent state directories (SPEC §8.3): the head's, resolved
    // through `AppPaths` the way the scope does it, and the desktop's.
    app = AppController(
      () async => AppPaths('${tempDir.path}/phone'),
      now: DateTime.now,
    );
    localRoot = await Directory('${tempDir.path}/phone-documents/notes')
        .create(recursive: true);
    remoteRoot = await Directory('${tempDir.path}/desktop/notes')
        .create(recursive: true);
    desktopStateDir = '${tempDir.path}/desktop-state';
    await Directory(desktopStateDir).create();
    desktopStore = PairedDeviceStore(
      File('$desktopStateDir/paired-devices.json'),
    );
    desktopSessionErrors = [];

    // `dsync agent --serve`'s half, bound first because the payload has to
    // name the port it serves on: the same identity the payload pins, the
    // same store the enrolment writes to, an ephemeral port read back.
    agent = await AgentListener.bindSecure(
      InternetAddress.loopbackIPv4,
      0,
      ownIdentity: desktopIdentity,
      pairedDeviceStore: desktopStore,
      buildAgent: desktopAgent,
      onSessionError: (error, _) => desktopSessionErrors.add(error),
    );
    agentPort = _portOf(agent.address);

    // The pairing, driven through the head's own controller against a real
    // enrolment listener — `dsync pair show`'s half, minus the printing.
    final token = generateEnrolmentToken();
    final enrolmentErrors = <Object>[];
    enrolment = await EnrolmentListener.bind(
      InternetAddress.loopbackIPv4,
      0,
      ownIdentity: desktopIdentity,
      token: token,
      tokenExpiresAt: DateTime.now().add(defaultEnrolmentTokenTtl),
      pairedDeviceStore: desktopStore,
      onError: (error, _) => enrolmentErrors.add(error),
    );
    enrolmentPort = _portOf(enrolment.address);
    pairingPayload = PairingPayload(
      certificateDer: certificateDerFromPem(desktopIdentity.certificatePem),
      address: PeerAddress(host: '127.0.0.1', port: enrolmentPort),
      // What `dsync pair show --serve-port` puts in the payload: where the
      // agent answers, never the one-shot enrolment listener's own port.
      servicePort: agentPort,
      token: token,
    );
    // Both stay up past this setUp: the pairing round below is what the rest
    // of this file drives from, and the re-read case is about what a
    // *second* code on the same controller — the page's, which lives as
    // long as the pairing does — must not do, with the listener that
    // already spent this payload's token still able to answer it.
    pair = PairController(app, enrol: enrolWithPeer);
    pair.codeEntered(pairingPayload.encode());
    await pair
        .submitPayload(localName: 'desktop', proposedName: 'phone')
        .timeout(_startupDeadline);
    final outcome = pair.state.outcome;
    expect(
      outcome,
      isA<PairSucceeded>(),
      reason:
          'pairing did not succeed: '
          '${outcome is PairFailed ? outcome.message : outcome}; '
          'listener said: $enrolmentErrors',
    );
    phoneIdentity = await app.loadOrCreateIdentity();

  });

  tearDown(() async {
    await enrolment.close();
    await agent.close();
    pair.dispose();
    app.dispose();
    await tempDir.delete(recursive: true);
  });

  /// What the Run setup page would hand over for [remoteRootPath]: no
  /// address at all, so the run dials what the pairing cached. That is the
  /// point of the payload carrying the serving port — after `dsync pair
  /// show` exits and `dsync agent --serve` keeps running, the first sync
  /// works without anyone re-entering a port.
  RunRequest request(String remoteRootPath) => RunRequest(
    localRootPath: localRoot.path,
    deviceName: 'desktop',
    peerDeviceId: desktopIdentity.deviceId,
    remoteRootPath: remoteRootPath,
    addressOverride: null,
    jobs: 2,
    dryRun: false,
  );

  /// Drives one run to its end through the real `dialPeer`, answering the
  /// conflict sheet with "accept all" the moment it opens — a non-dry run
  /// with anything to do parks there and waits (`SyncRunController.present`).
  /// The phase is polled, bounded, rather than awaited off a listener,
  /// because `start` is what is being awaited and it does not return until
  /// the sheet is answered.
  Future<SyncRunPhase> drive(RunRequest request) async {
    final controller = SyncRunController(
      app,
      dial: dialPeer,
      screenWake: FakeScreenWake(),
    );
    addTearDown(controller.dispose);
    final started = controller.start(request);
    final deadline = DateTime.now().add(_startupDeadline);
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
      if (DateTime.now().isAfter(deadline)) {
        fail(
          'run never reached the sheet or an end; still $phase. '
          'Desktop said: $desktopSessionErrors',
        );
      }
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    await started.timeout(_startupDeadline);
    return controller.state.phase;
  }

  Future<List<FileSystemEntity>> archivesIn(String directory) =>
      Directory(directory)
          .list()
          .where((entity) => entity.path.endsWith('.jsonl'))
          .toList();

  test('pairing records each side under its own chosen name, with no roots '
      'agreed (SPEC §4.4)', () async {
    // The head's store: the desktop, under the name the head chose, with
    // the *serving* address cached as the first thing to try — not the
    // enrolment listener's ephemeral port, which is gone the moment
    // pairing ends.
    final onPhone = await (await app.pairedDevices).byName('desktop');
    expect(onPhone, isNotNull);
    expect(onPhone!.deviceId, desktopIdentity.deviceId);
    expect(onPhone.agreedReplicaRoots, isEmpty);
    expect(onPhone.lastKnownAddress.host, '127.0.0.1');
    expect(onPhone.lastKnownAddress.port, agentPort);
    expect(onPhone.lastKnownAddress.port, isNot(enrolmentPort));
    // Names are local to the side that chose them: the head never sees
    // "phone", and the desktop never sees "desktop".
    expect(await (await app.pairedDevices).byName('phone'), isNull);

    final onDesktop = await desktopStore.byName('phone');
    expect(onDesktop, isNotNull);
    expect(onDesktop!.deviceId, phoneIdentity.deviceId);
    expect(onDesktop.agreedReplicaRoots, isEmpty);
    expect(await desktopStore.byName('desktop'), isNull);

    // `submitPayload`'s last step: the Devices page already shows it.
    expect(app.state.devices.map((row) => row.name), ['desktop']);
  });

  test('the same code read again, its token already burned, dials nothing '
      '(SPEC §4.4)', () async {
    // The premise is the desktop's own, and it is live: this payload's token
    // was spent by the round in `setUp`, and the listener that spent it is
    // still listening. So anything that dialled on a re-read would get
    // exactly what that costs — a connection, and an
    // `EnrolmentRefusedException` back — and the Pair page would go from
    // "paired" to "the desktop refused this pairing" over a pairing that
    // had just worked. What reading a code has to be instead: an input.
    final seen = <PairOutcome>[];
    pair.state.addListener(() => seen.add(pair.state.outcome));

    pair.codeEntered(pairingPayload.encode());

    expect(
      pair.state.code,
      isA<PairCodeRead>(),
      reason: 'the burned code still decodes; it is the token that is spent',
    );
    expect(
      seen.whereType<PairSubmitting>(),
      isEmpty,
      reason: 'reading a code must start no exchange: ${seen.join(' -> ')}',
    );
    // Still one entry on the desktop's side: nothing was dialled, as a
    // refused second redemption could not have added one either.
    expect((await desktopStore.load()).length, 1);
  });

  test('a granted root syncs both ways over loopback TLS, over the address '
      'the pairing cached (SPEC §2, §4.4)', () async {
    await desktopStore.grant(phoneIdentity.deviceId, remoteRoot.path);
    await File('${localRoot.path}/top.txt').writeAsString('from phone');
    await Directory('${localRoot.path}/deep').create();
    await File('${localRoot.path}/deep/nested.txt').writeAsString('nested');
    await File('${remoteRoot.path}/from-desktop.txt')
        .writeAsString('from desktop');

    final phase = await drive(request(remoteRoot.path));

    expect(
      phase,
      isA<SyncRunFinished>(),
      reason:
          '${phase is SyncRunFailed ? phase.message : phase}; desktop '
          'said: $desktopSessionErrors',
    );
    final finished = phase as SyncRunFinished;
    expect(finished.applied, 3);
    expect(finished.skipped, 0);
    expect(finished.conflicts, 0);
    expect(finished.failed, 0);
    expect(finished.unreadable, 0);
    expect(desktopSessionErrors, isEmpty);

    // Real bytes on real disk, in both directions.
    expect(
      await File('${remoteRoot.path}/top.txt').readAsString(),
      'from phone',
    );
    expect(
      await File('${remoteRoot.path}/deep/nested.txt').readAsString(),
      'nested',
    );
    expect(
      await File('${localRoot.path}/from-desktop.txt').readAsString(),
      'from desktop',
    );

    // SPEC §7.3, §8.3: each side committed an archive in its own state
    // directory — the head's under `AppPaths.stateDir`, the desktop's
    // where `desktopAgent` put it.
    expect(await archivesIn((await app.paths).stateDir), hasLength(1));
    expect(await archivesIn(desktopStateDir), hasLength(1));

    // The address that worked is what stays on file for the next run.
    final onPhone = await (await app.pairedDevices).byName('desktop');
    expect(onPhone!.lastKnownAddress.port, agentPort);
  });

  test('a root the pairing did not grant is refused with the not-granted line, '
      'and nothing is written (SPEC §4.4)', () async {
    await desktopStore.grant(phoneIdentity.deviceId, remoteRoot.path);
    final other = await Directory('${tempDir.path}/desktop/other').create();
    await File('${localRoot.path}/top.txt').writeAsString('from phone');

    final phase = await drive(request(other.path));

    // The handshake succeeds — this device *is* paired — and the `hello`
    // is what gets refused, in-band, as the line the Run page renders.
    expect(phase, isA<SyncRunFailed>());
    expect(
      (phase as SyncRunFailed).message,
      remoteRootNotGrantedMessage(
        deviceName: 'desktop',
        remoteRoot: other.path,
      ),
    );
    expect(await other.list().toList(), isEmpty);
    expect(await archivesIn(desktopStateDir), isEmpty);
  });

  test('a pairing the desktop revoked is refused below Channel, as unreachable '
      '(SPEC §4.4)', () async {
    await desktopStore.grant(phoneIdentity.deviceId, remoteRoot.path);
    await desktopStore.revoke(phoneIdentity.deviceId);
    await File('${localRoot.path}/top.txt').writeAsString('from phone');

    final phase = await drive(request(remoteRoot.path));

    // The head still trusts the desktop, but its own certificate is no
    // longer a trust anchor over there, so the handshake fails before any
    // frame is exchanged: `ReplicaConnector` renders that as the peer not
    // answering, with the cached address named.
    expect(phase, isA<SyncRunFailed>());
    expect(
      (phase as SyncRunFailed).message,
      allOf(
        startsWith('Could not reach "desktop" at 127.0.0.1:$agentPort'),
        contains('Enter its address by hand'),
      ),
    );
    expect(
      desktopSessionErrors.whereType<NoPairedDevicesException>(),
      hasLength(1),
      reason: 'desktop said: $desktopSessionErrors',
    );
    expect(await remoteRoot.list().toList(), isEmpty);
  });
}

/// The port a listener was actually given, read off its `host:port`
/// address — the reason both listeners take port 0 and read it back.
int _portOf(String address) =>
    int.parse(address.substring(address.lastIndexOf(':') + 1));
