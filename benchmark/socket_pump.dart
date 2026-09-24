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
//              the sender's writes or is a property of the record / buffer;
//   plain-iso, tls-iso, adapter-iso — plain, tls and adapter with the
//              receiver in a background isolate (Isolate.spawn from the one
//              `receive` runs on): the isolate builds its own SecurityContext
//              from the same seed, binds, accepts, handshakes and reads, and
//              sends its report back;
//   tls-iso-busy — tls-iso while the spawning isolate burns 4 ms of every
//              16 ms frame from accept to the isolate's exit, a stand-in for
//              the app's own work on the UI isolate.
// On the phone `receive` runs on the Flutter root isolate, whose event loop
// is the embedder's UI task runner; a spawned isolate has a plain Dart
// message loop. A secure socket's every read event takes a trip through that
// loop (the filter is run via _IOService._dispatch and Timer.run).
// Per case the phone prints MiB/s over its own clock from the first byte to
// the last, the read count, read events, bytes per read (mean/max) and the
// gaps between reads (p50/p90/max). The desktop prints its own rate to the
// last write accepted and to the phone's close, so a sender-bound case shows.
// Reading it: plain/raw near 26 MiB/s and tls near 8 puts the ceiling in the
// TLS layer; raw well under plain's puts it in dart:io's raw read path; tls
// near raw with adapter at 8 puts it in dsync's adapter. tls-iso well above
// tls puts the cost in the root isolate's embedder event loop (and receiving
// in a background isolate escapes it; tls-iso-busy says whether it still does
// with the UI isolate working); tls-iso equal to tls puts it elsewhere.
// Desktop reference, 127.0.0.1, 128 MiB: under `dart run` every TLS case,
// -iso or not, runs at 290–375 MiB/s; in the Flutter Linux app
// (`flutter drive --profile -d linux`) tls/adapter/tls-big drop to 3.3 MiB/s
// at 1.1 ms per ~4 KiB read while tls-iso/adapter-iso/tls-iso-busy stay at
// 317–361 MiB/s.
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
// Phone half (listens on PORT..PORT+8, one port per case in the order above:
// plain +0, raw +1, tls +2, adapter +3, tls-big +4, plain-iso +5, tls-iso +6,
// adapter-iso +7, tls-iso-busy +8; prints its addresses, ends once every case
// in CASES, default all, has been served once; ~1–2 min at 128 MiB):
//   flutter drive --profile -d <serial> \
//     --driver=test_driver/integration_test.dart \
//     --target=integration_test/socket_pump_probe_test.dart \
//     [--dart-define=PORT=47470] [--dart-define=CASES=tls,tls-iso,…]
// (`flutter test integration_test/socket_pump_probe_test.dart -d <serial>`
// works too, but runs the Dart side in debug JIT; --profile is AOT like the
// shipped app, and is what the other on-device probes use.)
//
// Desktop half, once the phone prints `listening` (bench phone 192.168.0.61;
// the phone half also prints its interface addresses):
//   dart run benchmark/socket_pump.dart send --host 192.168.0.61 \
//     [--port 47470] [--mib 128] [--chunk-kib 256] [--big-chunk-kib 4096] \
//     [--cases …, default all; must match the phone's CASES]
//
// Desktop-only check, both halves on this host over 127.0.0.1:
//   dart run benchmark/socket_pump.dart receive [--port 47470] [--cases …]
//   dart run benchmark/socket_pump.dart send --host 127.0.0.1
// or with the Flutter Linux app as the receiver (then the same `send`):
//   flutter drive --profile -d linux \
//     --driver=test_driver/integration_test.dart \
//     --target=integration_test/socket_pump_probe_test.dart
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
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
/// the phone receives it, whether the sender offers its big writes, and
/// whether the receiver runs in a background isolate rather than the one
/// [receive] was called on (with the caller's isolate kept busy meanwhile
/// for [busyRoot]).
enum PumpCase {
  plain(0, PumpReceiver.socket, secure: false),
  raw(1, PumpReceiver.rawSocket, secure: false),
  tls(2, PumpReceiver.rawSecureSocket, secure: true),
  adapter(3, PumpReceiver.rawSecureByteSocket, secure: true),
  tlsBig(4, PumpReceiver.rawSecureSocket, secure: true, bigWrites: true),
  plainIso(5, PumpReceiver.socket, secure: false, inIsolate: true),
  tlsIso(6, PumpReceiver.rawSecureSocket, secure: true, inIsolate: true),
  adapterIso(
    7,
    PumpReceiver.rawSecureByteSocket,
    secure: true,
    inIsolate: true,
  ),
  tlsIsoBusy(
    8,
    PumpReceiver.rawSecureSocket,
    secure: true,
    inIsolate: true,
    busyRoot: true,
  );

  final int portOffset;
  final PumpReceiver receiver;
  final bool secure;
  final bool bigWrites;
  final bool inIsolate;
  final bool busyRoot;

  const PumpCase(
    this.portOffset,
    this.receiver, {
    required this.secure,
    this.bigWrites = false,
    this.inIsolate = false,
    this.busyRoot = false,
  });

  /// `tlsIsoBusy` → `tls-iso-busy`.
  String get label =>
      name.replaceAllMapped(RegExp('[A-Z]'), (m) => '-${m[0]!.toLowerCase()}');

  /// Every case: the default for both halves.
  static String get allLabels => values.map((c) => c.label).join(',');

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
    return '${pumpCase.label.padRight(12)} '
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
  final context = _serverContext();

  for (final interface in await NetworkInterface.list()) {
    for (final address in interface.addresses) {
      log('address ${interface.name} ${address.address}');
    }
  }

  final served = <Future<void>>[];
  for (final pumpCase in cases) {
    final at = port + pumpCase.portOffset;
    if (pumpCase.inIsolate) {
      await _listenInIsolate(pumpCase, at, log, served);
    } else {
      await _listen(pumpCase, at, context, log, served);
    }
    log('listening ${pumpCase.label} on port $at');
  }
  await Future.wait(served);
  log('done');
}

/// The receiving side's context: the probe identity, a client certificate
/// required to be that same identity.
SecurityContext _serverContext() {
  final identity = probeIdentity();
  return SecurityContext(withTrustedRoots: false)
    ..useCertificateChainBytes(utf8.encode(identity.certificatePem))
    ..usePrivateKeyBytes(utf8.encode(identity.privateKeyPem))
    ..setTrustedCertificatesBytes(utf8.encode(identity.certificatePem));
}

/// Binds [pumpCase]'s receiver on [at] in the calling isolate and adds to
/// [served] a future that completes once its one connection has been read
/// and reported. [onAccepted] runs as that connection arrives.
Future<void> _listen(
  PumpCase pumpCase,
  int at,
  SecurityContext context,
  void Function(String line) log,
  List<Future<void>> served, {
  void Function()? onAccepted,
}) async {
  void report(ReadLog reads) => log(reads.report(pumpCase));
  // Logged and not rethrown, so one failed case leaves the others served.
  void failed(Object error) => log('${pumpCase.label} failed: $error');
  if (pumpCase.receiver == PumpReceiver.socket) {
    final server = await ServerSocket.bind(InternetAddress.anyIPv4, at);
    served.add(
      server.first
          .then((socket) async {
            onAccepted?.call();
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
            onAccepted?.call();
            await server.close();
            return _readRaw(pumpCase, socket, context);
          })
          .then(report, onError: failed),
    );
  }
}

/// What a background receiver sends the isolate that spawned it besides its
/// log lines (Strings), sent as the index.
enum _IsolateSignal { bound, accepted }

/// [_listen] for [pumpCase] inside a new isolate: the isolate builds its own
/// SecurityContext from the same seed, binds, accepts, handshakes and reads,
/// and sends back its log lines. Returns once it is bound, and adds to
/// [served] a future that completes once the isolate has exited.
Future<void> _listenInIsolate(
  PumpCase pumpCase,
  int at,
  void Function(String line) log,
  List<Future<void>> served,
) async {
  final messages = ReceivePort();
  final bound = Completer<void>();
  final exited = Completer<void>();
  void Function()? stopBusy;
  messages.listen((message) {
    switch (message) {
      case String line:
        log(line);
      case int signal:
        switch (_IsolateSignal.values[signal]) {
          case _IsolateSignal.bound:
            bound.complete();
          case _IsolateSignal.accepted:
            if (pumpCase.busyRoot) stopBusy = _keepBusy();
        }
      case [final error, _]: // onError
        log('${pumpCase.label} failed: $error');
      case null: // onExit
        stopBusy?.call();
        messages.close();
        if (!bound.isCompleted) bound.complete();
        exited.complete();
    }
  });
  await Isolate.spawn(
    _receiveInIsolate,
    (messages.sendPort, pumpCase.index, at),
    onError: messages.sendPort,
    onExit: messages.sendPort,
  );
  served.add(exited.future);
  await bound.future;
}

Future<void> _receiveInIsolate((SendPort, int, int) message) async {
  final (root, caseIndex, at) = message;
  final served = <Future<void>>[];
  await _listen(
    PumpCase.values[caseIndex],
    at,
    _serverContext(),
    root.send,
    served,
    onAccepted: () => root.send(_IsolateSignal.accepted.index),
  );
  root.send(_IsolateSignal.bound.index);
  await Future.wait(served);
}

/// Stands in for the app's own work on the root isolate while a background
/// isolate receives: 4 ms of computation in every 16 ms frame. Returns its
/// stop.
void Function() _keepBusy() {
  final timer = Timer.periodic(const Duration(milliseconds: 16), (_) {
    final spin = Stopwatch()..start();
    while (spin.elapsedMicroseconds < 4000) {}
  });
  return timer.cancel;
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
      '${pumpCase.label.padRight(12)} sent ${mib.toStringAsFixed(0)} MiB in '
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
    ..addOption('cases', defaultsTo: PumpCase.allLabels);
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
