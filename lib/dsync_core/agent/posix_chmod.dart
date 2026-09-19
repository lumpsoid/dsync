import 'dart:ffi';

import 'package:ffi/ffi.dart';

/// Applies POSIX permission bits to [nativePath], best-effort (SPEC §7.4).
///
/// Takes a **native** path — the spelling the host's own filesystem uses, not
/// the `/`-normalized wire form (SPEC §3) — because it goes straight to the
/// C library.
///
/// Returns `chmod(2)`'s own result: `0` when the bits landed, `-1` when the
/// call ran and the filesystem refused it. That second case is not an error
/// here: Android's shared storage does not carry POSIX modes (SPEC §3), and
/// §7.4's rule is that the write still succeeds and the archive records the
/// mode that actually landed rather than the one that was asked for. It is a
/// per-path outcome, and the next path may well succeed.
///
/// Throws [ChmodUnavailable] when there is no `chmod` on this host *at all*,
/// which is a different claim entirely — it is about the host, not the path,
/// so it is the one `LocalAgent._chmodUnavailable` latches on and stops
/// asking.
typedef Chmod = int Function(String nativePath, int mode);

/// Thrown by a [Chmod] that cannot run on this host at all, as distinct from
/// one that ran and the filesystem refused.
///
/// The successor to the `ProcessException` the old shell-out latched on: same
/// meaning, same latch, but raised by a failed symbol lookup rather than a
/// failed process start.
class ChmodUnavailable implements Exception {
  final String reason;

  const ChmodUnavailable(this.reason);

  @override
  String toString() => 'chmod is unavailable on this host: $reason';
}

/// `chmod(2)` through `dart:ffi` — the default [Chmod].
///
/// **Why FFI rather than the `Process.run('chmod', …)` this replaces.** Dart
/// has no chmod, so the mode step used to be a fork and an exec, once per
/// copied file: a measured 14,471 spawns for 14,471 files on a real run, and
/// the largest single term in the destination's own work. A syscall removes
/// both without changing the per-file order of anything around it.
///
/// **No pre-`stat` guards this.** The old code read the file's current mode
/// first, because skipping a spawn was worth a stat. It is not worth a
/// syscall — the guard cost about what the thing it guarded does — so the
/// caller applies the mode unconditionally and the stat is gone with the
/// fork.
///
/// Windows never reaches here: `LocalAgent` starts latched there (SPEC §3),
/// and the lookup would fail anyway — the C runtime spells it `_chmod` and
/// its mode bits mean something else. That is what [ChmodUnavailable] is
/// for, not a case this pretends to serve.
int posixChmod(String nativePath, int mode) {
  final chmod = _resolveChmod();
  final path = nativePath.toNativeUtf8();
  try {
    return chmod(path, mode);
  } finally {
    malloc.free(path);
  }
}

typedef _ChmodNative = Int Function(Pointer<Utf8>, UnsignedInt);
typedef _ChmodDart = int Function(Pointer<Utf8>, int);

/// Resolved once and remembered. Nothing caches the *failure*: a host that
/// cannot resolve the symbol raises [ChmodUnavailable] and the caller's own
/// latch is what stops it being asked again, so the "never ask twice"
/// guarantee stays in the one place it always lived.
_ChmodDart? _chmod;

_ChmodDart _resolveChmod() {
  final resolved = _chmod;
  if (resolved != null) return resolved;
  try {
    // `process()`, not `open('libc.so')`: `chmod` is already in every process
    // this runs in, and naming a library file would mean naming a different
    // one per platform (`libc.so.6`, `libSystem.dylib`) for no gain.
    return _chmod = DynamicLibrary.process()
        .lookupFunction<_ChmodNative, _ChmodDart>('chmod');
  } on Object catch (error) {
    throw ChmodUnavailable('$error');
  }
}
