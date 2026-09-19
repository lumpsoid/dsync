import 'dart:io';

import 'package:dsync/dsync_core/state_dir.dart';
import 'package:path/path.dart' as p;

/// Advisory lock on one replica's state directory (SPEC §4.3), held against
/// every other holder on the host — in this process and in any other.
///
/// Taken by an `Agent` before scanning and released on every exit path,
/// including after a failed run.
///
/// **Two mechanisms, because one of them does not cover both cases.** The
/// OS file lock is what serializes against a second `dsync` process: a CLI
/// run while the app is syncing, two `dsync sync` invocations on the same
/// profile. It does *not* serialize against this process's own other
/// holders — POSIX advisory locks are owned by the process, so a second
/// descriptor opened here is granted the lock immediately (verified: a
/// second `lock(FileLock.exclusive)` in one process returns at once). That
/// left a real hole the moment anything but a run wanted this lock: the
/// Flutter head runs its sync in the same process as its UI, so deleting an
/// archive from the Archives page while that run held the replica would have
/// been granted, and the run would have rebuilt a log the next run then
/// refuses as a mismatched header (SPEC §8.1). [_heldInProcess] closes it —
/// the same answer, [ReplicaLockHeldException], from whichever side the
/// second holder comes.
class ReplicaLock {
  /// Canonical paths this process currently holds a lock on. Static because
  /// the thing being excluded is a *second* [ReplicaLock] over the same
  /// path: two instances are exactly the case the OS lock cannot see, so
  /// per-instance state could not answer it.
  static final Set<String> _heldInProcess = {};

  final File _lockFile;
  RandomAccessFile? _handle;

  ReplicaLock(this._lockFile);

  /// The path of the file this lock is taken on.
  String get path => _lockFile.path;

  /// Resolves the standard per-replica lock path (SPEC §4.3, §8.3):
  /// `$XDG_STATE_HOME/dsync/<profileId>-<side>.lock`, defaulting
  /// `XDG_STATE_HOME` to `~/.local/state` when unset. [platform] is required,
  /// not defaulted: every caller states which of SPEC §8.3's rules it means
  /// rather than silently getting Linux's — see [resolveLockPath].
  factory ReplicaLock.forProfile({
    required String profileId,
    required String side,
    Map<String, String> environment = const {},
    required StateDirPlatform platform,
  }) {
    return ReplicaLock(
      resolveLockPath(
        profileId: profileId,
        side: side,
        environment: environment,
        platform: platform,
      ),
    );
  }

  /// Takes the lock. Throws a [ReplicaLockHeldException] if anything else
  /// already holds it — another process, or another [ReplicaLock] in this
  /// one — which is fatal for the caller (SPEC §11.5 exit 3).
  ///
  /// The in-process claim is staked before the file is touched, and given
  /// back if the OS lock is refused, so a failed acquire leaves nothing
  /// behind for the next attempt to trip over.
  Future<void> acquire() async {
    final key = _key;
    if (!_heldInProcess.add(key)) {
      throw ReplicaLockHeldException(_lockFile.path);
    }
    try {
      await _lockFile.parent.create(recursive: true);
      final handle = await _lockFile.open(mode: FileMode.write);
      try {
        await handle.lock(FileLock.exclusive);
      } on FileSystemException {
        await handle.close();
        throw ReplicaLockHeldException(_lockFile.path);
      }
      _handle = handle;
    } catch (_) {
      _heldInProcess.remove(key);
      rethrow;
    }
  }

  /// Releases the lock taken by [acquire]. A no-op if [acquire] was never
  /// called or did not succeed, so it is safe to call on every exit path
  /// (SPEC §4.3).
  Future<void> release() async {
    final handle = _handle;
    if (handle == null) return;
    _handle = null;
    _heldInProcess.remove(_key);
    await handle.unlock();
    await handle.close();
  }

  /// This lock's identity within the process: the canonical path, so two
  /// spellings of the same lock file — a trailing slash on a state
  /// directory, a `..` in a test's temp path — are one entry rather than
  /// two, and the in-process guard cannot be walked around by accident.
  String get _key => p.canonicalize(_lockFile.absolute.path);
}

/// Thrown by [ReplicaLock.acquire] when another run already holds the lock
/// (SPEC §4.3) — fatal for the caller (SPEC §11.5 exit 3).
class ReplicaLockHeldException implements Exception {
  final String path;

  const ReplicaLockHeldException(this.path);

  @override
  String toString() => 'Replica lock held: $path';
}

/// The standard per-replica lock path (SPEC §4.3, §8.3):
/// `<state dir>/<profileId>-<side>.lock`. See [resolveStateDir]. [platform]
/// is required, not defaulted: a hardcoded default here would silently
/// resolve the wrong directory on every platform but the one it names, which
/// is worse than a compile error naming every caller that owes one — see
/// `lib/cli/host_platform.dart` for where the CLI head's real answer comes
/// from.
File resolveLockPath({
  required String profileId,
  required String side,
  Map<String, String> environment = const {},
  required StateDirPlatform platform,
}) {
  return File(
    '${resolveStateDir(environment, platform)}/$profileId-$side.lock',
  );
}
