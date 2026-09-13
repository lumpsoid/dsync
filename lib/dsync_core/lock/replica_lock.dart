import 'dart:io';

/// Advisory OS-level lock on one replica's state directory (SPEC §4.3).
///
/// Taken by an `Agent` before scanning and released on every exit path,
/// including after a failed run. Backed by a real file lock rather than
/// in-memory state, so it also serializes against a second `dsync` process on
/// the same host — not just concurrent calls within this one.
class ReplicaLock {
  final File _lockFile;
  RandomAccessFile? _handle;

  ReplicaLock(this._lockFile);

  /// The path of the file this lock is taken on.
  String get path => _lockFile.path;

  /// Resolves the standard per-replica lock path (SPEC §4.3, §8.3):
  /// `$XDG_STATE_HOME/dsync/<profileId>-<side>.lock`, defaulting
  /// `XDG_STATE_HOME` to `~/.local/state` when unset.
  factory ReplicaLock.forProfile({
    required String profileId,
    required String side,
    Map<String, String> environment = const {},
  }) {
    return ReplicaLock(
      resolveLockPath(
        profileId: profileId,
        side: side,
        environment: environment,
      ),
    );
  }

  /// Takes the lock. Throws a [ReplicaLockHeldException] if another run
  /// already holds it — fatal for the caller (SPEC §11.5 exit 3).
  Future<void> acquire() async {
    await _lockFile.parent.create(recursive: true);
    final handle = await _lockFile.open(mode: FileMode.write);
    try {
      await handle.lock(FileLock.exclusive);
    } on FileSystemException {
      await handle.close();
      throw ReplicaLockHeldException(_lockFile.path);
    }
    _handle = handle;
  }

  /// Releases the lock taken by [acquire]. A no-op if [acquire] was never
  /// called or did not succeed, so it is safe to call on every exit path
  /// (SPEC §4.3).
  Future<void> release() async {
    final handle = _handle;
    if (handle == null) return;
    _handle = null;
    await handle.unlock();
    await handle.close();
  }
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
/// `$XDG_STATE_HOME/dsync/<profileId>-<side>.lock`, defaulting
/// `XDG_STATE_HOME` to `~/.local/state` when unset.
///
/// Pure function of [environment] — takes no environment implicitly — so it
/// is testable without touching the filesystem or real process environment.
File resolveLockPath({
  required String profileId,
  required String side,
  Map<String, String> environment = const {},
}) {
  final stateHome =
      environment['XDG_STATE_HOME'] ?? '${environment['HOME']}/.local/state';
  return File('$stateHome/dsync/$profileId-$side.lock');
}
