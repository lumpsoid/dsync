/// Not Windows: `dart:io` has no unix-domain sockets there.
@TestOn('!windows')
library;

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:dsync/dsync_core/protocol/socket_channel.dart';
import 'package:test/test.dart';

/// [SocketChannel] against a real unix socket — no agent, no protocol, just
/// the three methods [Channel] is (SPEC §4.2).
///
/// `unix_socket_e2e_test.dart` proves a whole sync runs over this; what is
/// here is the part that would be diagnosed as a sync bug if it broke: chunk
/// boundaries carrying no meaning, and a close that actually reaches the
/// peer as an EOF rather than just abandoning the connection.
void main() {
  late Directory tempDir;
  late String socketPath;
  late ServerSocket server;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('dsync_socket_channel_');
    socketPath = '${tempDir.path}/agent.sock';
    server = await ServerSocket.bind(
      InternetAddress(socketPath, type: InternetAddressType.unix),
      0,
    );
  });

  tearDown(() async {
    await server.close();
    await tempDir.delete(recursive: true);
  });

  test('bytes cross in both directions, in order', () async {
    server.listen((socket) {
      socket.listen(
        (chunk) => socket.add([for (final byte in chunk) byte + 1]),
        onDone: socket.close,
      );
    });

    final channel = await SocketChannel.connectUnix(socketPath);
    final received = channel.input.expand((chunk) => chunk).take(6).toList();

    await channel.send(Uint8List.fromList([1, 2, 3]));
    await channel.send(Uint8List.fromList([4, 5, 6]));

    // Chunk boundaries carry no meaning (`Channel.input`), so this asserts
    // the byte sequence rather than how it arrived split.
    expect(await received, [2, 3, 4, 5, 6, 7]);
    await channel.close();
  });

  test('close is the EOF that ends the peer\'s session', () async {
    // What `AgentServer.serve` returns on: its input stream completing. A
    // close that only abandoned this end would leave the far side waiting
    // for a frame that is never coming.
    final peerSawEof = Completer<void>();
    server.listen((socket) {
      socket.listen((_) {}, onDone: () => peerSawEof.complete());
    });

    final channel = await SocketChannel.connectUnix(socketPath);
    await channel.send(Uint8List.fromList([1]));
    await channel.close();

    await expectLater(peerSawEof.future, completes);
  });

  test('connecting where nothing is listening fails, rather than hanging on '
      'a socket file that outlived its agent', () async {
    // The shape a killed agent leaves behind: the inode is still there, so
    // this is not a "no such file" — it is a refused connection, which is
    // what `resolveReplicaAgents` reports as an unreachable replica (SPEC
    // §11.5 exit 3).
    final stale = '${tempDir.path}/stale.sock';
    await File(stale).writeAsString('');

    await expectLater(
      SocketChannel.connectUnix(stale),
      throwsA(isA<SocketException>()),
    );
  });

  group('Nagle', () {
    test(
      'a unix socket is left alone, because it refuses the option',
      () async {
        // Why `SocketChannel`'s constructor asks the transport instead of
        // setting `TCP_NODELAY` unconditionally: `TCP_NODELAY` is a TCP option,
        // and a unix socket does not quietly ignore it — it throws. An
        // unconditional set would break every `unix://` connection in the
        // project, so this pins the refusal rather than leaving the branch
        // looking like superstition someone should tidy away.
        server.listen((socket) => socket.destroy());
        final raw = await Socket.connect(
          InternetAddress(socketPath, type: InternetAddressType.unix),
          0,
        );
        addTearDown(raw.destroy);

        expect(
          () => raw.setOption(SocketOption.tcpNoDelay, true),
          // A bare `OSError`, not a `SocketException` — `setOption` lets
          // `setsockopt`'s `EOPNOTSUPP` straight through unwrapped.
          throwsA(isA<OSError>()),
        );

        // And the channel over that same transport still constructs.
        expect(() => SocketChannel(raw), returnsNormally);
      },
    );

    test(
      'a TCP socket takes it, on both the dialed and the accepted end',
      () async {
        // The end that matters, and the one that cannot be asserted by reading
        // the option back — `dart:io` has no getter. What is checked is that
        // the constructor accepts both ends of a real TCP pair and the bytes
        // still cross: an option that threw, or a branch that skipped TCP and
        // left Nagle on, would be caught by the measurement in SPEC §17 rather
        // than here.
        final tcp = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
        addTearDown(tcp.close);

        final accepted = Completer<SocketChannel>();
        tcp.listen((socket) => accepted.complete(SocketChannel(socket)));

        final dialed = SocketChannel(
          await Socket.connect(InternetAddress.loopbackIPv4, tcp.port),
        );
        final peer = await accepted.future;
        final received = peer.input.expand((chunk) => chunk).take(3).toList();

        await dialed.send(Uint8List.fromList([7, 8, 9]));

        expect(await received, [7, 8, 9]);
        await dialed.close();
        await peer.close();
      },
    );
  });
}
