import 'dart:io';
import 'dart:isolate';

/// The real Dart CLI, which is **not** `Platform.resolvedExecutable` when the
/// test host is `flutter test`.
///
/// Under `dart test`, `resolvedExecutable` is the `dart` binary and passing it
/// `['compile', 'exe', ...]` works. Under `flutter test` it is `flutter_tester`
/// — the engine binary the test harness runs suites inside — which has no
/// `compile` or `run` subcommand at all. It does not reject the arguments and
/// exit non-zero, though: it starts, does nothing, and never exits, so the
/// `Process.run` awaiting it never completes. Every suite that did this timed
/// out and leaked an immortal `flutter_tester compile exe` process behind it.
///
/// So: use `resolvedExecutable` only when it really is `dart`, and otherwise
/// find the SDK that the Flutter tool ships. `FLUTTER_ROOT` is set by the
/// `flutter` wrapper for exactly this purpose; the walk up from the engine
/// artifact path is the fallback for a host that somehow runs `flutter_tester`
/// without it, and bare `dart` on `PATH` is the last resort.
String get dartExecutable {
  final resolved = Platform.resolvedExecutable;
  if (_basename(resolved) == 'dart' || _basename(resolved) == 'dart.exe') {
    return resolved;
  }

  final flutterRoot = Platform.environment['FLUTTER_ROOT'];
  if (flutterRoot != null && flutterRoot.isNotEmpty) {
    final candidate =
        '$flutterRoot${Platform.pathSeparator}bin'
        '${Platform.pathSeparator}dart';
    if (File(candidate).existsSync()) return candidate;
  }

  // .../flutter/bin/cache/artifacts/engine/<host>/flutter_tester -> .../flutter
  var dir = File(resolved).parent;
  for (var i = 0; i < 5; i++) {
    dir = dir.parent;
  }
  final fromEngine =
      '${dir.path}${Platform.pathSeparator}bin'
      '${Platform.pathSeparator}dart';
  if (File(fromEngine).existsSync()) return fromEngine;

  return 'dart';
}

String _basename(String path) => path.split(Platform.pathSeparator).last;

/// Where the shared test binary lives. Under `/build/`, which is gitignored,
/// rather than a per-suite `Directory.systemTemp.createTemp` — the whole point
/// is that suites share it.
const _relativeBinaryPath = 'build/dsync_test/dsync';
const _lockPath = 'build/dsync_test/.compile.lock';

/// Exists while one isolate of this process is compiling — see
/// [dsyncTestBinary].
const _claimPath = 'build/dsync_test/.compiling';

/// How old a claim may be before it is presumed abandoned. A compile takes
/// ~6s here and well under a minute on a loaded CI runner.
const _claimTimeout = Duration(minutes: 2);

/// How often a waiting isolate re-checks for a fresh binary.
const _claimPollInterval = Duration(milliseconds: 250);

/// The binary path, absolute. Several call sites hand `Process.run` a
/// `workingDirectory` inside the replica under test, against which a relative
/// path to this binary would not resolve.
String get _binaryPath =>
    '${Directory.current.path}${Platform.pathSeparator}$_relativeBinaryPath';

/// Compiles `bin/dsync.dart` once and returns the path to the executable,
/// shared by every suite that needs to spawn the real CLI as a process.
///
/// Seven suites need this binary, and `flutter test` runs suites concurrently
/// in separate processes, so before this helper existed all seven raced to
/// build their own private copy of the identical artifact at the same moment.
/// In-process memoization cannot dedupe that — the suites are not in the same
/// process — so the guard is a lock file: the first suite to take it compiles,
/// the rest block, and by the time they wake the artifact is already there and
/// fresh, so they skip straight to using it.
///
/// Freshness is mtime against every Dart source under `lib/` and `bin/` plus
/// `pubspec.yaml`. That is the same question `dart compile` would answer
/// internally, asked cheaply enough (a directory walk, no process spawn) to be
/// worth asking before paying for a ~6s compile that a `flutter test` rerun
/// over untouched sources would otherwise repeat seven times.
///
/// Under `dart test` the suites are isolates of *one* process, and the lock
/// above does nothing there: a POSIX `fcntl` lock is owned by the process, so
/// a second isolate taking it succeeds at once. Two more guards cover that
/// host, and cost nothing under `flutter test` where the lock already
/// serialises everything:
///
/// - Only one isolate compiles at a time. Whoever creates [_claimPath]
///   exclusively — an atomic create-if-absent — is the compiler; the rest
///   poll until the binary is fresh. A claim left behind by a run killed
///   mid-compile is not honoured past [_claimTimeout], so a stale one costs
///   one wait, not a hang; a compile genuinely slower than that on a loaded
///   machine gets a second, duplicate compile, which the next point makes
///   harmless.
/// - Nothing ever opens [_binaryPath] itself for writing. Writing into a
///   file another suite is already executing is refused by the kernel with
///   `ETXTBSY` ("Text file busy"), failing both the compile and any spawn
///   that overlaps it. So the compiler is pointed at a path private to this
///   isolate, and the finished artifact is renamed onto [_binaryPath] — an
///   atomic replace that leaves a process already running the old file on
///   the old inode.
Future<String> dsyncTestBinary() async {
  await Directory('build/dsync_test').create(recursive: true);

  final lockFile = File(_lockPath).openSync(mode: FileMode.write);
  await lockFile.lock(FileLock.blockingExclusive);
  try {
    while (!await _isFresh()) {
      if (await _claimCompile()) {
        try {
          await _compile();
        } finally {
          try {
            await File(_claimPath).delete();
          } on FileSystemException {
            // Already removed by a waiter that presumed this compile
            // abandoned (see [_claimCompile]); nothing left to release.
          }
        }
      } else {
        await Future<void>.delayed(_claimPollInterval);
      }
    }
    return _binaryPath;
  } finally {
    await lockFile.unlock();
    await lockFile.close();
  }
}

/// Takes the compile claim if nobody holds a live one. `true` means this
/// isolate compiles.
Future<bool> _claimCompile() async {
  final claim = File(_claimPath);
  if (claim.existsSync()) {
    final age = DateTime.now().difference(claim.lastModifiedSync());
    if (age < _claimTimeout) return false;
    // Abandoned. Whoever deletes it first goes on to race for a fresh
    // claim; losing that race is the ordinary `false` below.
    try {
      claim.deleteSync();
    } on FileSystemException {
      return false;
    }
  }
  try {
    await claim.create(exclusive: true);
    return true;
  } on FileSystemException {
    return false;
  }
}

/// Compiles into an isolate-private staging path, then renames it onto
/// [_binaryPath].
Future<void> _compile() async {
  final staging = File('$_binaryPath.$pid-${Isolate.current.hashCode}');
  final compile = await Process.run(dartExecutable, [
    'compile',
    'exe',
    'bin/dsync.dart',
    '-o',
    staging.path,
  ]);
  if (compile.exitCode != 0) {
    if (await staging.exists()) await staging.delete();
    throw StateError(
      'failed to compile bin/dsync.dart with "$dartExecutable":\n'
      '${compile.stderr}',
    );
  }
  await staging.rename(_binaryPath);
}

/// Whether the built binary is newer than every source that goes into it.
Future<bool> _isFresh() async {
  final binary = File(_binaryPath);
  if (!binary.existsSync()) return false;
  final builtAt = binary.lastModifiedSync();

  for (final dir in [Directory('lib'), Directory('bin')]) {
    await for (final entity in dir.list(recursive: true)) {
      if (entity is! File || !entity.path.endsWith('.dart')) continue;
      if (entity.lastModifiedSync().isAfter(builtAt)) return false;
    }
  }

  final pubspec = File('pubspec.yaml');
  if (pubspec.existsSync() && pubspec.lastModifiedSync().isAfter(builtAt)) {
    return false;
  }

  return true;
}
