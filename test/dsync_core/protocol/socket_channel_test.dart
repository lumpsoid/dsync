@TestOn('linux')
library;

import 'dart:async';
import 'dart:io';

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

    await channel.send([1, 2, 3]);
    await channel.send([4, 5, 6]);

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
    await channel.send([1]);
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
}
