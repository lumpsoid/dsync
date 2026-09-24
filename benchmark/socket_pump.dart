// Where a large peer:// pull's ~7.8 MiB/s ceiling on the phone comes from
// (task 4dc926). Not part of the build.
//
// A 270 MiB pull onto the phone reaches Dart in ~70,000 reads of 4.0 KiB mean
// (8.0 KiB max), ~2,000 reads/s, with the phone's event loop idle; raw TCP over
// the same association (`nc` → toybox `nc`) runs at 26 MiB/s. This pumps
// --mib MiB from the desktop into the phone once per case, each case on its
// own port, and the phone reports what its side saw. One thing varies per
// case, the receiving socket stack:
//   plain    — ServerSocket/Socket, dart:io's stream (each data event a read);
//   raw      — RawServerSocket/RawSocket, read() until null on each read event;
//   tls      — RawSecureSocket accepted as AgentListener.bindSecure accepts
//              (RawServerSocket, then secureServerWithin with a client
//              certificate required), read() until null per read event;
//   adapter  — the same TLS accept wrapped in RawSecureByteSocket, dsync's
//              own adapter, each `input` chunk a read: what the adapter adds;
//   tls-big  — `tls` again, the sender offering --big-chunk-kib per write
//              instead of --chunk-kib: whether the ~4 KiB read size follows
//              the sender's writes or is a property of the record / buffer.
// Per case the phone prints MiB/s over its own clock from the first byte to
// the last, the read count, read events, bytes per read (mean/max) and the
// gaps between reads (p50/p90/max). The desktop prints its own rate to the
// last write accepted and to the phone's close, so a sender-bound case shows.
// Reading it: plain/raw near 26 MiB/s and tls near 8 puts the ceiling in the
// TLS layer; raw well under plain's puts it in dart:io's raw read path; tls
// near raw with adapter at 8 puts it in dsync's adapter.
//
// TLS is production's configuration: default SecurityContext (so TLS version
// and cipher are BoringSSL's defaults, as in production), certificate and key
// from this project's own self-signed generator, the server requiring a client
// certificate that is its trust anchor, the client pinning the server's
// certificate in onBadCertificate. Both ends derive one probe identity from a
// fixed seed ([probeIdentity]), so nothing is exchanged and nothing is stored.
// One difference from a real pull: here the phone is the TLS server, where a
// pull's phone may be the client; after the handshake TLS 1.3 is symmetric.
//
// Phone half (listens on PORT..PORT+4, prints its addresses, ends once every
// case in CASES has been served once; ~1 min at the default 128 MiB):
//   flutter drive --profile -d <serial> \
//     --driver=test_driver/integration_test.dart \
//     --target=integration_test/socket_pump_probe_test.dart \
//     [--dart-define=PORT=47470] [--dart-define=CASES=plain,raw,tls,adapter,tls-big]
// (`flutter test integration_test/socket_pump_probe_test.dart -d <serial>`
// works too, but runs the Dart side in debug JIT; --profile is AOT like the
// shipped app, and is what the other on-device probes use.)
//
// Desktop half, once the phone prints `listening` (bench phone 192.168.0.61;
// the phone half also prints its interface addresses):
//   dart run benchmark/socket_pump.dart send --host 192.168.0.61 \
//     [--port 47470] [--mib 128] [--chunk-kib 256] [--big-chunk-kib 4096] \
//     [--cases plain,raw,tls,adapter,tls-big]
//
// Desktop-only check, both halves on this host over 127.0.0.1:
//   dart run benchmark/socket_pump.dart receive [--port 47470] [--cases …]
//   dart run benchmark/socket_pump.dart send --host 127.0.0.1
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:args/args.dart';
import 'package:dsync/dsync_core/identity/self_signed_certificate.dart';
import 'package:dsync/dsync_core/models/device_identity.dart';
import 'package:dsync/dsync_core/protocol/bounded_secure_handshake.dart';
import 'package:dsync/dsync_core/protocol/raw_secure_byte_socket.dart';
import 'package:pointycastle/export.dart';

const defaultPumpPort = 47470;
const _handshakeDeadline = Duration(seconds: 15);

/// One measured case: the port it is served on (base + [portOffset]), how
/// the phone receives it, and whether the sender offers its big writes.
enum PumpCase {
  plain(0, PumpReceiver.socket, secure: false),
  raw(1, PumpReceiver.rawSocket, secure: false),
  tls(2, PumpReceiver.rawSecureSocket, secure: true),
  adapter(3, PumpReceiver.rawSecureByteSocket, secure: true),
  tlsBig(4, PumpReceiver.rawSecureSocket, secure: true, bigWrites: true);

  final int portOffset;
  final PumpReceiver receiver;
  final bool secure;
  final bool bigWrites;

  const PumpCase(
    this.portOffset,
    this.receiver, {
    required this.secure,
    this.bigWrites = false,
  });

  String get label => this == tlsBig ? 'tls-big' : name;

  static List<PumpCase> parse(String list) => [
    for (final label in list.split(','))
      if (label.trim().isNotEmpty)
        values.firstWhere(
          (c) => c.label == label.trim(),
          orElse: () => throw ArgumentError('unknown case "$label"'),
        ),
  ];
}

enum PumpReceiver { socket, rawSocket, rawSecureSocket, rawSecureByteSocket }

/// The probe's one identity, derived from a fixed seed and date so the phone
/// and the desktop generate the same certificate without exchanging it.
/// Probe-only: the key is as public as this file.
DeviceIdentity probeIdentity() => generateDeviceIdentity(
  commonName: 'dsync-socket-pump',
  random: FortunaRandom()..seed(KeyParameter(Uint8List(32))),
  now: DateTime.utc(2026, 1, 1),
);

/// What one connection's reads looked like on the receiving side.
class ReadLog {
  final Stopwatch _clock = Stopwatch()..start();
  final List<int> _at = [];
  final List<int> _sizes = [];
  int events = 0;

  void read(int bytes) {
    _at.add(_clock.elapsedMicroseconds);
    _sizes.add(bytes);
  }

  String report(PumpCase pumpCase) {
    if (_at.isEmpty) return '${pumpCase.label}: no bytes';
    final bytes = _sizes.fold<int>(0, (a, b) => a + b);
    final spanUs = max(1, _at.last - _at.first);
    final gaps = [for (var i = 1; i < _at.length; i++) _at[i] - _at[i - 1]]
      ..sort();
    String ms(int us) => (us / 1000).toStringAsFixed(2);
    String pct(double p) =>
        gaps.isEmpty ? '-' : ms(gaps[((gaps.length - 1) * p).round()]);
    final mib = bytes / (1 << 20);
    return '${pumpCase.label.padRight(8)} '
        '${(mib / (spanUs / 1e6)).toStringAsFixed(1)} MiB/s  '
        '${mib.toStringAsFixed(0)} MiB in ${(spanUs / 1e6).toStringAsFixed(2)} s  '
        'reads ${_at.length} (${(_at.length / (spanUs / 1e6)).round()}/s)'
        '${events > 0 ? ' events $events' : ''}  '
        'bytes/read mean ${(bytes / _at.length / 1024).toStringAsFixed(1)} KiB '
        'max ${(_sizes.reduce(max) / 1024).toStringAsFixed(1)} KiB  '
        'gap ms p50 ${pct(0.5)} p90 ${pct(0.9)} '
        'max ${gaps.isEmpty ? '-' : ms(gaps.last)}';
  }
}

/// The phone half: listens for every case in [cases] at once, on
/// [port] + its offset, serves each connection to its EOF and reports it,
/// and returns once every case has been served once.
Future<void> receive({
  required int port,
  required List<PumpCase> cases,
  required void Function(String line) log,
}) async {
  final identity = probeIdentity();
  final context = SecurityContext(withTrustedRoots: false)
    ..useCertificateChainBytes(utf8.encode(identity.certificatePem))
    ..usePrivateKeyBytes(utf8.encode(identity.privateKeyPem))
    ..setTrustedCertificatesBytes(utf8.encode(identity.certificatePem));

  for (final interface in await NetworkInterface.list()) {
    for (final address in interface.addresses) {
      log('address ${interface.name} ${address.address}');
    }
  }

  final served = <Future<void>>[];
  for (final pumpCase in cases) {
    final at = port + pumpCase.portOffset;
    void report(ReadLog reads) => log(reads.report(pumpCase));
    // Logged and not rethrown, so one failed case leaves the others served.
    void failed(Object error) => log('${pumpCase.label} failed: $error');
    if (pumpCase.receiver == PumpReceiver.socket) {
      final server = await ServerSocket.bind(InternetAddress.anyIPv4, at);
      served.add(
        server.first
            .then((socket) async {
              await server.close();
              return _readSocket(socket);
            })
            .then(report, onError: failed),
      );
    } else {
      final server = await RawServerSocket.bind(InternetAddress.anyIPv4, at);
      served.add(
        server.first
            .then((socket) async {
              await server.close();
              return _readRaw(pumpCase, socket, context);
            })
            .then(report, onError: failed),
      );
    }
    log('listening ${pumpCase.label} on port $at');
  }
  await Future.wait(served);
  log('done');
}

Future<ReadLog> _readSocket(Socket socket) async {
  final reads = ReadLog();
  await socket.forEach((chunk) => reads.read(chunk.length));
  socket.destroy();
  return reads;
}

Future<ReadLog> _readRaw(
  PumpCase pumpCase,
  RawSocket socket,
  SecurityContext context,
) async {
  if (pumpCase.receiver == PumpReceiver.rawSocket) {
    return _readRawEvents(socket);
  }
  final secured = await secureServerWithin(
    socket,
    context,
    requireClientCertificate: true,
    deadline: _handshakeDeadline,
  );
  try {
    if (pumpCase.receiver == PumpReceiver.rawSecureSocket) {
      return await _readRawEvents(secured);
    }
    final adapter = RawSecureByteSocket(secured);
    final reads = ReadLog();
    await adapter.input.forEach((chunk) => reads.read(chunk.length));
    adapter.destroy();
    return reads;
  } finally {
    // As AgentListener does: RawSecureSocket.close is never awaited, the
    // plain socket underneath is what gets the descriptor back.
    secured.close().ignore();
    await socket.close();
  }
}

/// Reads [socket] the way RawSecureByteSocket's read pump does: read() until
/// it returns null on every read event.
Future<ReadLog> _readRawEvents(RawSocket socket) {
  final reads = ReadLog();
  final done = Completer<ReadLog>();
  socket.listen(
    (event) {
      switch (event) {
        case RawSocketEvent.read:
          reads.events++;
          while (true) {
            // A plain RawSocket's read() asserts that bytes are available
            // (debug builds), so it is asked first; a RawSecureSocket is
            // read exactly as the adapter reads it, until null.
            final chunk = socket is RawSecureSocket || socket.available() > 0
                ? socket.read()
                : null;
            if (chunk == null || chunk.isEmpty) break;
            reads.read(chunk.length);
          }
        case RawSocketEvent.readClosed:
        case RawSocketEvent.closed:
          if (!done.isCompleted) done.complete(reads);
        default:
          break;
      }
    },
    onError: (Object error, StackTrace stack) {
      if (!done.isCompleted) done.completeError(error, stack);
    },
    onDone: () {
      if (!done.isCompleted) done.complete(reads);
    },
  );
  return done.future.whenComplete(() {
    if (socket is! RawSecureSocket) socket.close();
  });
}

/// The desktop half: one connection per case, [bytes] each, offered in
/// writes of [chunk] (or [bigChunk] for a big-writes case).
Future<void> send({
  required String host,
  required int port,
  required List<PumpCase> cases,
  required int bytes,
  required int chunk,
  required int bigChunk,
}) async {
  final identity = probeIdentity();
  final context = SecurityContext(withTrustedRoots: false)
    ..useCertificateChainBytes(utf8.encode(identity.certificatePem))
    ..usePrivateKeyBytes(utf8.encode(identity.privateKeyPem));
  final pinned = identity.certificateDer;

  for (final pumpCase in cases) {
    final writeSize = pumpCase.bigWrites ? bigChunk : chunk;
    final raw = await RawSocket.connect(host, port + pumpCase.portOffset);
    final RawSocket socket;
    if (pumpCase.secure) {
      socket = await secureClientWithin(
        raw,
        host: host,
        context: context,
        deadline: _handshakeDeadline,
        onBadCertificate: (certificate) => _sameBytes(certificate.der, pinned),
      );
    } else {
      socket = raw;
    }
    final (:written, :closed) = await _pump(socket, bytes, writeSize);
    raw.close().ignore();
    final mib = bytes / (1 << 20);
    stdout.writeln(
      '${pumpCase.label.padRight(8)} sent ${mib.toStringAsFixed(0)} MiB in '
      '${(writeSize / 1024).round()} KiB writes: '
      '${(mib / written).toStringAsFixed(1)} MiB/s to the last write '
      '(${written.toStringAsFixed(2)} s), '
      '${(mib / closed).toStringAsFixed(1)} MiB/s to the phone\'s close '
      '(${closed.toStringAsFixed(2)} s)',
    );
    // Lets the phone print before the next case's bytes arrive.
    await Future<void>.delayed(const Duration(milliseconds: 500));
  }
}

bool _sameBytes(Uint8List a, Uint8List b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

/// Writes [total] bytes as fast as [socket] takes them, offering at most
/// [chunk] per write, then half-closes and waits for the far end to close.
/// Returns seconds to the last byte accepted and to the far end's close.
Future<({double written, double closed})> _pump(
  RawSocket socket,
  int total,
  int chunk,
) {
  final buffer = Uint8List(chunk);
  for (var i = 0; i < chunk; i++) {
    buffer[i] = i * 31;
  }
  final clock = Stopwatch()..start();
  final done = Completer<({double written, double closed})>();
  var sent = 0;
  var offset = 0;
  double? written;

  void fill() {
    while (sent < total) {
      final length = min(chunk - offset, total - sent);
      final n = socket.write(buffer, offset, length);
      sent += n;
      offset = (offset + n) % chunk;
      if (n < length) {
        socket.writeEventsEnabled = true;
        return;
      }
    }
    if (written == null) {
      written = clock.elapsedMicroseconds / 1e6;
      socket.shutdown(SocketDirection.send);
    }
  }

  void finish() {
    if (done.isCompleted) return;
    done.complete((
      written: written ?? double.nan,
      closed: clock.elapsedMicroseconds / 1e6,
    ));
  }

  socket.listen(
    (event) {
      switch (event) {
        case RawSocketEvent.write:
          fill();
        case RawSocketEvent.read:
          socket.read();
        case RawSocketEvent.readClosed:
        case RawSocketEvent.closed:
          finish();
      }
    },
    onError: (Object error, StackTrace stack) {
      if (!done.isCompleted) done.completeError(error, stack);
    },
    onDone: finish,
  );
  fill();
  return done.future;
}

Future<void> main(List<String> arguments) async {
  final parser = ArgParser()
    ..addOption('host', defaultsTo: '127.0.0.1')
    ..addOption('port', defaultsTo: '$defaultPumpPort')
    ..addOption('mib', defaultsTo: '128')
    ..addOption('chunk-kib', defaultsTo: '256')
    ..addOption('big-chunk-kib', defaultsTo: '4096')
    ..addOption('cases', defaultsTo: 'plain,raw,tls,adapter,tls-big');
  final parsed = parser.parse(arguments);
  final port = int.parse(parsed.option('port')!);
  final cases = PumpCase.parse(parsed.option('cases')!);
  switch (parsed.rest) {
    case ['send']:
      await send(
        host: parsed.option('host')!,
        port: port,
        cases: cases,
        bytes: int.parse(parsed.option('mib')!) << 20,
        chunk: int.parse(parsed.option('chunk-kib')!) << 10,
        bigChunk: int.parse(parsed.option('big-chunk-kib')!) << 10,
      );
    case ['receive']:
      await receive(port: port, cases: cases, log: stdout.writeln);
    default:
      stderr.writeln(
        'usage: dart run benchmark/socket_pump.dart send|receive\n'
        '${parser.usage}',
      );
      exitCode = 64;
  }
}
