import 'dart:async';
import 'dart:collection';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

/// A file's first block, read with a blocking call on an isolate of its own.
///
/// [complete] is the whole point: a short read means end of file, so the
/// caller knows the file is in hand without a `stat` — one syscall this would
/// otherwise have to pay per file to decide which path to take.
class ReadHead {
  const ReadHead(this.bytes, {required this.complete});

  final Uint8List bytes;

  /// Whether [bytes] is the whole file. False means the file is at least
  /// [ReadPool.blockBytes] long and the rest must be read from that offset.
  final bool complete;
}

/// Reads the head of a file on a pool of long-lived isolates, so the read is
/// a blocking syscall on a thread of its own rather than a message to the
/// VM's bounded native-port pool (task 9d2158 §15, §19).
///
/// **Why this exists.** `ReadProbe` measures this phone's tree at 28.4 MiB/s
/// through `readAsBytesSync` in isolates against `openRead`'s 10.9 at the
/// same four-way spread, and 35.1 against 18.7 at eight. `readAsBytes` is
/// within 7% of `openRead`, so the gap is not streaming's per-block
/// dispatches — it is the asynchronous mechanism itself, and the only way out
/// of it is a thread that may block. `Scanner._hashAll` already had four such
/// threads and took its content read 2.2× by using them (§17); the apply had
/// none, and this is them.
///
/// **Long-lived, and that is not an implementation detail.** One
/// `Isolate.run` per file would be 14,471 spawns on the measured tree, which
/// is exactly the shape §9.5 found in `peer chmod` — one fork and one exec
/// per file, 73.5 s of it — and removed. A pool that spawns per request would
/// reintroduce it one layer up.
///
/// **Only the head.** A worker reads [blockBytes] and stops, so its memory is
/// one block per worker whatever the file, and a caller that finds
/// [ReadHead.complete] false streams the remainder from that offset. On the
/// measured tree 13,148 of 14,471 files — 90.9% — were already read whole
/// inside a 64 KiB cap by `ReadAhead` (SPEC §7.2), so the head *is* the file
/// for nine of every ten, and the tenth loses nothing: its first block would
/// have been read anyway and is handed over rather than re-read.
class ReadPool {
  /// Isolates spawned on first use.
  ///
  /// **Eight, to match where the curve peaks and where the apply actually
  /// sits.** `ReadProbe`'s blocking mode tops out at depth 8 on this device
  /// (35.08 MiB/s, against 28.40 at four and 34.00 at sixteen) and the apply
  /// runs 7.8 reads in flight. More would buy nothing — §4 finding 2 has the
  /// blocking curve *declining* past sixteen — and each one costs a block of
  /// memory and a thread.
  final int workers;

  /// How much of a file one request reads. 64 KiB, which is `ReadAhead`'s own
  /// per-stream cap and `dart:io`'s stream block, so "the head" and "what a
  /// prefetch would have buffered" are the same quantity.
  final int blockBytes;

  final List<_Worker> _idle = [];
  final Queue<Completer<_Worker>> _waiting = Queue();

  Future<void>? _starting;
  bool _closed = false;

  ReadPool({this.workers = 8, this.blockBytes = 64 * 1024})
    : assert(workers >= 1, 'A pool with no workers reads nothing');

  /// The first [blockBytes] of [absolutePath], read on a worker.
  ///
  /// Throws the same [FileSystemException] the file would have thrown on a
  /// direct read — rebuilt on this side, because an exception does not cross
  /// a port and a caller must not be able to tell where the read happened.
  Future<ReadHead> read(String absolutePath) async {
    if (_closed) {
      throw StateError('This ReadPool is closed');
    }
    await (_starting ??= _spawn());
    final worker = await _take();
    try {
      return _unpack(await worker.ask(absolutePath), absolutePath);
    } finally {
      _release(worker);
    }
  }

  /// Stops every worker. Idempotent, and the pool cannot be used afterwards.
  ///
  /// **A leaked pool holds the process open** — a worker parked on its
  /// `ReceivePort` is a live isolate — so whoever owns one closes it on the
  /// way out. [LocalAgent] does this from `disconnect`.
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _starting;
    for (final worker in _idle) {
      worker.shutdown();
    }
    _idle.clear();
    // Anything still queued will never be served now; failing them is better
    // than leaving a caller awaiting a worker that is not coming.
    while (_waiting.isNotEmpty) {
      _waiting.removeFirst().completeError(
        StateError('This ReadPool was closed'),
      );
    }
  }

  Future<void> _spawn() async {
    final spawned = await Future.wait([
      for (var i = 0; i < workers; i++) _Worker.spawn(blockBytes),
    ]);
    if (_closed) {
      for (final worker in spawned) {
        worker.shutdown();
      }
      return;
    }
    _idle.addAll(spawned);
    // Whoever queued while the spawn was in flight goes first.
    while (_waiting.isNotEmpty && _idle.isNotEmpty) {
      _waiting.removeFirst().complete(_idle.removeLast());
    }
  }

  Future<_Worker> _take() {
    if (_idle.isNotEmpty) return Future.value(_idle.removeLast());
    final waiting = Completer<_Worker>();
    _waiting.add(waiting);
    return waiting.future;
  }

  void _release(_Worker worker) {
    if (_closed) {
      worker.shutdown();
      return;
    }
    if (_waiting.isNotEmpty) {
      _waiting.removeFirst().complete(worker);
      return;
    }
    _idle.add(worker);
  }

  ReadHead _unpack(Object? reply, String path) {
    if (reply case (final Uint8List bytes, final bool complete)) {
      return ReadHead(bytes, complete: complete);
    }
    final (String message, int? code, String osMessage) =
        reply as (String, int?, String);
    throw FileSystemException(
      message,
      path,
      code == null ? null : OSError(osMessage, code),
    );
  }
}

/// One worker isolate and the port it answers on.
///
/// A worker serves one request at a time, so its replies need no
/// correlation ids: the pool hands it out, waits, and takes it back.
class _Worker {
  _Worker._(this._requests, this._replies) {
    _replies.listen((reply) {
      final pending = _pending;
      _pending = null;
      pending?.complete(reply);
    });
  }

  final SendPort _requests;
  final ReceivePort _replies;
  Completer<Object?>? _pending;

  static Future<_Worker> spawn(int blockBytes) async {
    final handshake = ReceivePort();
    await Isolate.spawn(_serve, (
      handshake.sendPort,
      blockBytes,
    ), debugName: 'read-pool');
    final replies = ReceivePort();
    final requests = await handshake.first as SendPort;
    handshake.close();
    requests.send(replies.sendPort);
    return _Worker._(requests, replies);
  }

  Future<Object?> ask(String path) {
    final pending = _pending = Completer<Object?>();
    _requests.send(path);
    return pending.future;
  }

  void shutdown() {
    _requests.send(null);
    _replies.close();
  }
}

/// A worker's whole life: take a path, read its head with blocking calls,
/// send back the bytes or the reason there are none.
///
/// Top level because it is an isolate entry point. Failures cross as plain
/// values for the reason `Scanner`'s hash batch returns strings: a
/// [FileSystemException] cannot be thrown across a port, and one unreadable
/// file must not take the worker down with it.
void _serve((SendPort, int) args) {
  final (handshake, blockBytes) = args;
  final requests = ReceivePort();
  handshake.send(requests.sendPort);

  SendPort? replies;
  requests.listen((message) {
    if (message is SendPort) {
      replies = message;
      return;
    }
    if (message == null) {
      requests.close();
      return;
    }
    replies!.send(_readHead(message as String, blockBytes));
  });
}

/// One head read, as the record that crosses back: either `(bytes, complete)`
/// or `(message, errno, osMessage)`.
Object _readHead(String path, int blockBytes) {
  try {
    final file = File(path).openSync();
    try {
      // A fresh buffer per read rather than one reused per worker: the bytes
      // are sent onward, so a shared buffer would have to be copied out of
      // anyway and this way the copy is the send's.
      final buffer = Uint8List(blockBytes);
      final read = file.readIntoSync(buffer);
      return (
        read == blockBytes ? buffer : Uint8List.sublistView(buffer, 0, read),
        read < blockBytes,
      );
    } finally {
      file.closeSync();
    }
  } on FileSystemException catch (error) {
    return (
      error.message,
      error.osError?.errorCode,
      error.osError?.message ?? '',
    );
  }
}
