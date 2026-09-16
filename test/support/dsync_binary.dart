import 'dart:io';

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
Future<String> dsyncTestBinary() async {
  await Directory('build/dsync_test').create(recursive: true);

  final lockFile = File(_lockPath).openSync(mode: FileMode.write);
  await lockFile.lock(FileLock.blockingExclusive);
  try {
    if (await _isFresh()) return _binaryPath;

    final compile = await Process.run(dartExecutable, [
      'compile',
      'exe',
      'bin/dsync.dart',
      '-o',
      _binaryPath,
    ]);
    if (compile.exitCode != 0) {
      throw StateError(
        'failed to compile bin/dsync.dart with "$dartExecutable":\n'
        '${compile.stderr}',
      );
    }
    return _binaryPath;
  } finally {
    await lockFile.unlock();
    await lockFile.close();
  }
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
