import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dsync/dsync_core/agent/agent.dart';
import 'package:dsync/dsync_core/agent/agent_listener.dart';
import 'package:dsync/dsync_core/agent/local_agent.dart';
import 'package:dsync/dsync_core/agent/remote_agent.dart';
import 'package:dsync/dsync_core/archive/jsonl_archive_store.dart';
import 'package:dsync/dsync_core/identity/device_id.dart';
import 'package:dsync/dsync_core/identity/paired_device_store.dart';
import 'package:dsync/dsync_core/identity/self_signed_certificate.dart';
import 'package:dsync/dsync_core/lock/replica_lock.dart';
import 'package:dsync/dsync_core/models/archive.dart';
import 'package:dsync/dsync_core/models/device_identity.dart';
import 'package:dsync/dsync_core/models/paired_device.dart';
import 'package:dsync/dsync_core/models/replica_spec.dart';
import 'package:dsync/dsync_core/models/run_event.dart';
import 'package:dsync/dsync_core/protocol/control_message.dart';
import 'package:dsync/dsync_core/protocol/socket_channel.dart';
import 'package:dsync/dsync_core/run/run_controller.dart';
import 'package:test/test.dart';

/// Task 10cd32: the one security property the whole pairing line of work
/// (`589b90`) exists to provide, proven against real loopback TLS sockets —
/// an unpaired peer never reaches the protocol — plus the positive case that
/// makes the negative one meaningful: a paired, granted peer completing a
/// real bidirectional sync over the same transport.
///
/// **This does not duplicate `agent_listener_secure_test.dart`.** That file
/// already proves, at the unit level, that a stranger's handshake fails, that
/// a revoked device is refused despite a stale trust anchor, and that a
/// malformed certificate does not crash the listener. What it does *not* do
/// is look at what the refused peer's socket actually received, or run a
/// real sync end to end — both are this file's job.
///
/// ## The trap this whole file is built around
///
/// The obvious test is `expect(SecureSocket.connect(...), throwsA(...))`, and
/// it is wrong. Under TLS 1.3 the client sends its `Finished` message — and
/// so completes its own side of the handshake — before it has heard back
/// from the server, which validates the client's certificate only after
/// that. So `SecureSocket.connect` routinely *returns a live socket* for a
/// connection the server is, at that exact moment, in the middle of
/// rejecting: `connect`'s future resolves on the client's own progress, not
/// on the server's verdict. A test that asserts `connect` throws passes only
/// when it doesn't need to — i.e. it can report a clean pass while the
/// property it claims to prove is false, which is exactly what happened to a
/// first attempt at this test (see task 10cd32's body).
///
/// What is actually true, and what has to be asserted instead:
///
/// - **The server never surfaces a session for a refused peer.** Proven here
///   by wrapping `buildAgent` and recording every [ReplicaSpec] it is called
///   with — for all three refused peers, that list stays empty. That is a
///   stronger claim than "an error was logged": [AgentListener] reports a
///   TLS-layer handshake failure to [SessionErrorHandler] the same way it
///   reports a resolved-but-unrecognized peer (`UnrecognizedPeerException`),
///   so `onSessionError` firing does not by itself distinguish "no session
///   ever existed" from "a session existed and then failed". `buildAgent`
///   never running is what actually says no [Channel] and no [AgentServer]
///   were ever created for that connection.
/// - **The client's own socket received nothing**, not merely "the sync
///   failed". A sync that fails after the far end has already written a
///   version frame or a `hello` reply would still report failure — and would
///   still be the exact regression this test exists to catch, since it means
///   an unpaired peer reached dsync's own framed protocol before being
///   turned away. So every byte the refused socket's stream ever yields is
///   captured into a buffer, and the assertion is on that buffer being
///   empty — not on the shape of whatever exception surfaced.
/// - **The failure itself arrives asynchronously**, on the socket's `listen`
///   `onError`/`onDone` and on `done`, never from `add` (writing to a socket
///   that is about to be torn down does not itself throw). Both `listen` and
///   `done` are wired below; leaving either unhandled is not a quieter
///   version of this test, it is a test that crashes with an unhandled
///   asynchronous error instead of failing cleanly.
///
/// Empirically, all three refused peers below fail the same way: `connect`
/// returns a live socket, and that socket's stream then delivers a `Broken
/// pipe` [SocketException] — the server having reset the connection once its
/// own handshake or peer-resolution step rejected it — with nothing ever
/// read from it first. Confirmed by direct probing against this listener
/// before this file was written, the same way task 10cd32's own spike did
/// against a hand-rolled `SecureServerSocket` (8/8 rounds,
/// `strangerReachedServer=false`, `strangerReadFailed=true`).
///
/// ## The positive case, and its scoping gap
///
/// `unix_socket_e2e_test.dart` proves a whole sync over the unix transport by
/// driving the real CLI through a `unix://` location. There is no `peer://`
/// location yet (task 088e69, filed and not yet built), so the CLI cannot
/// name a secure replica at all — the positive case below is built one layer
/// down instead: a real [AgentListener.bindSecure] on one side, a real
/// [SocketChannel.connectSecure] + [RemoteAgent] on the other, and
/// [RunController] — the one owner of run ordering — driving them exactly as
/// it would drive any other pair of [Agent]s, over real temporary
/// directories. **A CLI-level version of this test waits on 088e69**; this
/// gap is deliberate and recorded here, not an oversight.
///
/// It also exercises the allowlist SPEC §4.4 requires on top of pairing
/// itself: [PairedDeviceStore.add] alone grants a device no replica roots at
/// all, so the positive case calls [PairedDeviceStore.grant] — deliberately
/// *after* [AgentListener.bindSecure] has already bound, to demonstrate that
/// the allowlist, like the trust anchors, is re-read fresh on every
/// connection, so granting a root to an already-paired device takes effect
/// without restarting the listener. Alongside it, a paired peer whose
/// root was never granted gets the refusal SPEC §4.4 asks for: one
/// indistinguishable [AgentOperationException], never a hint about whether
/// the path it asked for exists.
void main() {
  late Directory tempDir;
  late DeviceIdentity serverIdentity;
  late PairedDeviceStore store;
  late List<ReplicaSpec> buildAgentCalls;
  late List<Object> sessionErrors;

  const remoteHeader = ArchiveHeader(
    schemaVersion: 1,
    profileId: 'notes',
    rootPath: '/does/not/matter/remote',
  );
  const localHeader = ArchiveHeader(
    schemaVersion: 1,
    profileId: 'notes',
    rootPath: '/does/not/matter/local',
  );

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp(
      'dsync_agent_listener_secure_e2e_',
    );
    serverIdentity = generateDeviceIdentity(commonName: 'dsync-desktop');
    store = PairedDeviceStore(File('${tempDir.path}/paired-devices.json'));
    buildAgentCalls = [];
    sessionErrors = [];
  });

  tearDown(() async {
    await tempDir.delete(recursive: true);
  });

  /// The listener's own `buildAgent`, shared by every test: records every
  /// [ReplicaSpec] it is asked to build an [Agent] for, so a refused
  /// connection can be shown to have never reached it, and serves the
  /// connecting device's *actual* granted root — not a synthetic
  /// per-connection scratch directory the way `agent_listener_secure_test
  /// .dart`'s own `buildAgent` does — since the positive case below has to
  /// look at real files landing in it.
  Agent buildAgent(ReplicaSpec spec) {
    buildAgentCalls.add(spec);
    return LocalAgent(
      rootPath: spec.rootPath,
      archiveStore: JsonlArchiveStore(
        File('${tempDir.path}/remote-${spec.side}.jsonl'),
        remoteHeader,
      ),
      replicaLock: ReplicaLock(
        File('${tempDir.path}/remote-${spec.side}.lock'),
      ),
    );
  }

  Future<AgentListener> bind() => AgentListener.bindSecure(
    InternetAddress.loopbackIPv4,
    0,
    ownIdentity: serverIdentity,
    pairedDeviceStore: store,
    buildAgent: buildAgent,
    onSessionError: (error, _) => sessionErrors.add(error),
  );

  int portOf(AgentListener listener) {
    final address = listener.address;
    return int.parse(address.substring(address.lastIndexOf(':') + 1));
  }

  PairedDevice pairedDeviceFor(
    DeviceIdentity identity, {
    required String name,
    Set<String> roots = const {},
  }) => PairedDevice(
    certificatePem: identity.certificatePem,
    name: name,
    agreedReplicaRoots: roots,
    pairedAt: DateTime.utc(2026, 9, 15),
    lastKnownAddress: PeerAddress(host: '127.0.0.1'),
  );

  /// A client [SecurityContext] presenting [identity]'s certificate and key,
  /// or presenting nothing at all when [identity] is `null` — the "no
  /// identity" peer's own shape: a client that completes a TCP connection
  /// but never had a certificate to offer mutual TLS in the first place.
  SecurityContext clientContextFor(DeviceIdentity? identity) {
    final context = SecurityContext(withTrustedRoots: false);
    if (identity != null) {
      context
        ..useCertificateChainBytes(utf8.encode(identity.certificatePem))
        ..usePrivateKeyBytes(utf8.encode(identity.privateKeyPem));
    }
    return context;
  }

  /// Connects to [listener] as [identity] (or with no client certificate at
  /// all, for `identity: null`) and returns every byte the client's own
  /// socket stream ever yielded before its first read failed.
  ///
  /// See this file's class-level doc comment for why this cannot be written
  /// as `expect(SecureSocket.connect(...), throwsA(...))`. Both failure
  /// signals — the stream's `onError`/`onDone` and `done` itself — are
  /// wired before anything is written to the socket, and both funnel into
  /// one `Completer` rather than a timer: what this waits on is a fact
  /// about the socket (it has failed), not a fixed amount of wall-clock
  /// time, which is what keeps this deterministic instead of racing a
  /// handshake. `on HandshakeException` remains here only as a defensive
  /// fallback for a synchronous rejection this file's own probing never
  /// actually observed (see the class doc comment) — not the path any of
  /// the tests below rely on.
  Future<Uint8List> attemptAndCaptureBytes(
    DeviceIdentity? identity,
    AgentListener listener,
  ) async {
    final received = <int>[];
    final failed = Completer<void>();
    void markFailed() {
      if (!failed.isCompleted) failed.complete();
    }

    try {
      final socket = await SecureSocket.connect(
        InternetAddress.loopbackIPv4,
        portOf(listener),
        context: clientContextFor(identity),
        onBadCertificate: (c) =>
            _sameBytes(c.der, serverIdentity.certificateDer),
      );
      socket.listen(
        received.addAll,
        onError: (Object _) => markFailed(),
        onDone: markFailed,
        cancelOnError: true,
      );
      unawaited(socket.done.catchError((Object _) => markFailed()));
      socket.add(utf8.encode('anybody there?'));
      await failed.future.timeout(const Duration(seconds: 5));
      socket.destroy();
    } on HandshakeException {
      markFailed();
    }
    return Uint8List.fromList(received);
  }

  group('three peers that must never reach the protocol', () {
    test('no identity at all: a client with no certificate to offer gets '
        'nothing back, and buildAgent is never invoked for it', () async {
      final listener = await bind();
      addTearDown(listener.close);

      final received = await attemptAndCaptureBytes(null, listener);

      // Not "the sync failed" — the far side never sent a single byte:
      // no version frame, no hello reply, nothing a frame parser could
      // even attempt to decode.
      expect(received, isEmpty);
      // The server-side proof this is actually about: no Channel and no
      // AgentServer were ever created for this connection.
      expect(buildAgentCalls, isEmpty);
      expect(sessionErrors, isNotEmpty);
    });

    test('a well-formed identity that was never paired gets nothing back, and '
        'buildAgent is never invoked for it', () async {
      final stranger = generateDeviceIdentity(commonName: 'stranger');
      final listener = await bind();
      addTearDown(listener.close);

      final received = await attemptAndCaptureBytes(stranger, listener);

      expect(received, isEmpty);
      expect(buildAgentCalls, isEmpty);
      expect(sessionErrors, isNotEmpty);
    });

    test('a device paired and then revoked gets nothing back, and buildAgent '
        'is never invoked for it', () async {
      final revoked = generateDeviceIdentity(commonName: 'dsync-revoked');
      await store.add(
        pairedDeviceFor(revoked, name: 'revoked-phone', roots: {'/x'}),
      );
      final listener = await bind();
      addTearDown(listener.close);

      // Revoked after bind: the next accept rebuilds its SecurityContext
      // from the store as it is now, so this certificate is refused during
      // the handshake itself, the same as a stranger's.
      await store.revoke(deviceIdFromCertificateDer(revoked.certificateDer));

      final received = await attemptAndCaptureBytes(revoked, listener);

      expect(received, isEmpty);
      expect(buildAgentCalls, isEmpty);
      expect(sessionErrors, isNotEmpty);
    });
  });

  group('the positive case: a paired, granted peer syncs for real', () {
    test(
      'a full bidirectional sync over the secure transport: files move both '
      'ways and each side commits its own archive (SPEC §4.2, §4.4, §11.1)',
      () async {
        final localRoot = await Directory('${tempDir.path}/local').create();
        final remoteRoot = await Directory('${tempDir.path}/remote').create();

        final phone = generateDeviceIdentity(commonName: 'dsync-phone');
        // Paired with no roots at all yet — SPEC §4.4's allowlist is a
        // second, separate decision from trust (see `bindSecure`'s own doc
        // comment), and this proves that by exercising both halves: pairing
        // is done before bind, granting a root after it.
        await store.add(pairedDeviceFor(phone, name: 'phone'));

        final listener = await bind();
        addTearDown(listener.close);

        // Granted after the listener is already up: the allowlist check in
        // `_resolvePeer`/`_authorizedBuildAgent` re-reads the store fresh on
        // every connection.
        await store.grant(
          deviceIdFromCertificateDer(phone.certificateDer),
          remoteRoot.path,
        );

        await File('${localRoot.path}/top.txt').writeAsString('from local');
        await Directory('${localRoot.path}/notes').create();
        await File('${localRoot.path}/notes/deep.txt').writeAsString('nested');
        await File('${remoteRoot.path}/from-remote.txt')
            .writeAsString('from remote');

        final localArchiveLog = File('${tempDir.path}/local.jsonl');
        final agentA = LocalAgent(
          rootPath: localRoot.path,
          archiveStore: JsonlArchiveStore(localArchiveLog, localHeader),
          replicaLock: ReplicaLock(File('${tempDir.path}/local.lock')),
        );

        final channel = await SocketChannel.connectSecure(
          InternetAddress.loopbackIPv4.address,
          portOf(listener),
          expectedPeerCertificateDer: serverIdentity.certificateDer,
          ownIdentity: phone,
        );
        final agentB = RemoteAgent(
          channel,
          ReplicaSpec(
            rootPath: remoteRoot.path,
            profileId: 'notes',
            side: 'b',
            jobs: 2,
          ),
        );

        final events = await RunController(
          agentA: agentA,
          agentB: agentB,
          presenter: (plan) async => plan.actions,
        ).run().toList();

        final summary = events.whereType<RunSummaryEvent>().single;
        expect(
          summary.failedCount,
          0,
          reason: 'session errors seen: $sessionErrors',
        );
        expect(summary.appliedCount, 3);
        expect(summary.conflictCount, 0);

        // Both directions, and a path that made the applier create a
        // directory on the far side.
        expect(
          await File('${remoteRoot.path}/top.txt').readAsString(),
          'from local',
        );
        expect(
          await File('${remoteRoot.path}/notes/deep.txt').readAsString(),
          'nested',
        );
        expect(
          await File('${localRoot.path}/from-remote.txt').readAsString(),
          'from remote',
        );

        // Both archives committed — and the remote one is the interesting
        // half, the same as `unix_socket_e2e_test.dart`'s own reasoning: it
        // says the agent behind `bindSecure` genuinely ran a session and
        // wrote its own archive, not that this process did both sides'
        // work through a socket that happens to point at the same
        // filesystem.
        final archiveA = await JsonlArchiveStore(
          localArchiveLog,
          localHeader,
        ).load();
        final archiveB = await JsonlArchiveStore(
          File('${tempDir.path}/remote-b.jsonl'),
          remoteHeader,
        ).load();
        for (final path in const [
          'top.txt',
          'notes/deep.txt',
          'from-remote.txt',
        ]) {
          expect(archiveA.entries.containsKey(path), isTrue);
          expect(archiveB.entries.containsKey(path), isTrue);
        }

        // And the one paired, granted session that should exist actually
        // did — the positive mirror of every `buildAgentCalls` assertion
        // above.
        expect(buildAgentCalls, hasLength(1));
        expect(buildAgentCalls.single.rootPath, remoteRoot.path);
      },
    );

    test(
      'a paired peer whose root was never granted gets one generic '
      'AgentFailure that does not disclose whether the path exists',
      () async {
        // A root that genuinely exists on disk, unlike
        // `agent_listener_secure_test.dart`'s "outside the agreed set"
        // case, which never creates the path it names at all — this is the
        // sharper half of SPEC §4.4's "does not exist / unreadable / not
        // on your list" indistinguishability: the path is real, and the
        // refusal still has to look identical.
        final realButUngrantedRoot = await Directory(
          '${tempDir.path}/never-granted',
        ).create();

        final phone = generateDeviceIdentity(commonName: 'dsync-phone-2');
        await store.add(pairedDeviceFor(phone, name: 'phone-2')); // no roots
        final listener = await bind();
        addTearDown(listener.close);

        final channel = await SocketChannel.connectSecure(
          InternetAddress.loopbackIPv4.address,
          portOf(listener),
          expectedPeerCertificateDer: serverIdentity.certificateDer,
          ownIdentity: phone,
        );
        final agent = RemoteAgent(
          channel,
          ReplicaSpec(
            rootPath: realButUngrantedRoot.path,
            profileId: 'notes',
            side: 'b',
            jobs: 2,
          ),
        );

        await expectLater(
          agent.hello(),
          throwsA(
            isA<AgentOperationException>().having(
              (e) => e.message,
              'message',
              'This device is not authorized to reach that replica.',
            ),
          ),
        );
        // The refusal happened before `buildAgent` — and so the
        // filesystem — was ever touched, which is structurally what makes
        // the message above unable to say whether the path exists.
        expect(buildAgentCalls, isEmpty);
        await agent.disconnect();
      },
    );
  });
}

bool _sameBytes(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}
