// How the served side of a `peer://` connection reads what the desktop
// sends it, over the real TLS transport on loopback (task 7080d6). Not part
// of the build.
//
//   dart run benchmark/tls_read_probe.dart
//
// Sends `--files` small-file writes the way `RemoteAgent.writeFile` does —
// a request frame, a body frame, a terminator, three `Channel.send`s — all
// at once, so the receiver starts with a backlog; then a quarter as many
// paced at the phone's rate; then the same bytes as one send per file; then
// 64 KiB sends. For each it prints how many input chunks the receiver's
// `RawSecureByteSocket` delivered, their mean and largest size, and the
// rate. Each chunk is one read off `RawSecureSocket`.
//
// What it showed on a desktop: reads are at most 8 KiB and ~4 KiB on
// average whatever is sent, ~3.2 a small file, and the Dart TLS read path
// on both ends of one process turns over ~35,000 reads (~10,000 small files)
// a second — so on a desktop this transport is nowhere near 4 ms a file.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:args/args.dart';
import 'package:dsync/dsync_core/identity/self_signed_certificate.dart';
import 'package:dsync/dsync_core/protocol/raw_secure_byte_socket.dart';
import 'package:dsync/dsync_core/protocol/socket_channel.dart';

Future<void> main(List<String> arguments) async {
  final args =
      (ArgParser()
            ..addOption('files', defaultsTo: '1500')
            ..addOption('size', defaultsTo: '13312'))
          .parse(arguments);
  final files = int.parse(args.option('files')!);
  final size = int.parse(args.option('size')!);

  final header = Uint8List(120);
  final body = Uint8List(size + 9);
  final terminator = Uint8List(9);

  await _probe('3 sends a file (writeFile today)', files * (120 + size + 18), (
    channel,
  ) {
    return Future.wait([
      for (var i = 0; i < files; i++) ...[
        channel.send(header),
        channel.send(body),
        channel.send(terminator),
      ],
    ]);
  }, perFile: files);

  // The same three sends a file, but paced at the phone's measured rate
  // (one file per 4 ms) instead of all at once: what the receiver's reads
  // look like when it keeps up with the wire rather than draining a backlog.
  await _probe('3 sends a file, paced 4 ms', files ~/ 4 * (120 + size + 18), (
    channel,
  ) async {
    final sent = <Future<void>>[];
    for (var i = 0; i < files ~/ 4; i++) {
      sent
        ..add(channel.send(header))
        ..add(channel.send(body))
        ..add(channel.send(terminator));
      await Future<void>.delayed(const Duration(milliseconds: 4));
    }
    await Future.wait(sent);
  }, perFile: files ~/ 4);

  final joined = Uint8List(120 + size + 18);
  await _probe('1 send a file', files * joined.length, (channel) {
    return Future.wait([for (var i = 0; i < files; i++) channel.send(joined)]);
  }, perFile: files);

  final chunk = Uint8List(64 * 1024);
  const chunks = 320;
  await _probe('64 KiB sends (large file)', chunks * chunk.length, (channel) {
    return Future.wait([for (var i = 0; i < chunks; i++) channel.send(chunk)]);
  }, perFile: chunks);
}

Future<void> _probe(
  String label,
  int total,
  Future<void> Function(SocketChannel channel) send, {
  required int perFile,
}) async {
  final serverIdentity = generateDeviceIdentity(commonName: 'probe-server');
  final clientIdentity = generateDeviceIdentity(commonName: 'probe-client');
  final server = await RawServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  final accepted = Completer<RawSecureSocket>();
  server.listen((raw) {
    RawSecureSocket.secureServer(
      raw,
      SecurityContext(withTrustedRoots: false)
        ..useCertificateChainBytes(utf8.encode(serverIdentity.certificatePem))
        ..usePrivateKeyBytes(utf8.encode(serverIdentity.privateKeyPem)),
    ).then(accepted.complete, onError: accepted.completeError);
  });
  final client = await RawSecureSocket.connect(
    InternetAddress.loopbackIPv4,
    server.port,
    context: SecurityContext(withTrustedRoots: false)
      ..useCertificateChainBytes(utf8.encode(clientIdentity.certificatePem))
      ..usePrivateKeyBytes(utf8.encode(clientIdentity.privateKeyPem)),
    onBadCertificate: (_) => true,
  );
  final sender = SocketChannel.over(RawSecureByteSocket(client));
  final receiver = RawSecureByteSocket(await accepted.future);

  var reads = 0;
  var bytes = 0;
  var largest = 0;
  final done = Completer<void>();
  final clock = Stopwatch();
  receiver.input.listen((chunk) {
    if (reads == 0) clock.start();
    reads++;
    bytes += chunk.length;
    if (chunk.length > largest) largest = chunk.length;
    if (bytes >= total && !done.isCompleted) done.complete();
  });
  await send(sender);
  await done.future;
  final seconds = clock.elapsedMicroseconds / 1e6;
  stdout.writeln(
    '$label: ${(bytes / 1024 / 1024).toStringAsFixed(1)} MiB in '
    '$reads reads, ${(reads / perFile).toStringAsFixed(2)} per unit, '
    'mean ${(bytes / reads / 1024).toStringAsFixed(2)} KiB, '
    'largest $largest B, ${(reads / seconds).round()} reads/s, '
    '${(perFile / seconds).round()} units/s',
  );
  await sender.close();
  receiver.destroy();
  await server.close();
}
