// What `dart:io`'s per-path `stat` costs over one made against a directory
// handle (task 55bee6). Not part of the build.
//
// **The question.** This was variant 3 of task 7aa241 — "one `stat` for a whole
// directory's children if a lower-level call can be reached" — and it was moved
// out of that task because there is no such call. What `dart:io` does leave on
// the table is narrower and real: every `stat` it makes resolves an absolute
// path from the root, walking one directory entry per component, while `readdir`
// has already handed us a directory and a name. `fstatat(dirfd, name, …)` skips
// that resolution. Nobody has measured what it is worth, and SPEC §5 now prices
// everything around it, so this is the last unpriced term in the scan's walk.
//
// **The rungs**, each in a fresh VM, each visiting every file under the root:
//
//   io-stat       `Directory.listSync` for the listing, `File.statSync()` per
//                 file. The baseline, and the shape SPEC §5 recommends a
//                 blocking walk take.
//   ffi-stat      the same listing, libc `stat(path, …)` through FFI instead.
//                 The same syscall on the same absolute path, so the gap to
//                 `io-stat` is what `dart:io` adds *around* it — a `FileStat`, a
//                 `DateTime`, and the FFI boundary in the other direction.
//   ffi-fstatat   the same listing, but the directory is opened once and each
//                 child is stat'd by name against that handle. The gap to
//                 `ffi-stat` is path resolution, which is the number this task
//                 exists for.
//   ffi-getdents  no Dart listing at all: `getdents64` for names and `d_type`,
//                 `openat` to descend, `fstatat` by name. **No Dart string is
//                 built for any file** — the name is passed to `fstatat` as a
//                 pointer into the `getdents` buffer. The gap to `ffi-fstatat`
//                 is what the listing itself costs, and the rung as a whole is
//                 the honest upper bound on what leaving `dart:io` could buy.
//
// **`io-stat` doubles as the cross-check.** It is the same work as
// `stat_allocation_probe.dart`'s `stat-sync` rung minus that one's asynchronous
// listing, so the two scripts' figures have to be consistent with each other
// over the same tree. They are read off the same instrument (`gc_ladder.dart`),
// and a disagreement is a bug in one of the scripts rather than a finding.
//
// **Linux only, and not apologising for it.** It is the platform both ends of
// SPEC §3 run on. A win here would still need a `dart:io` fallback for macOS and
// Windows, which is a cost to weigh once there is a number.
//
//   dart run benchmark/dir_stat_probe.dart --root <dir>
//   dart run benchmark/dir_stat_probe.dart --root <dir> --rung ffi-getdents
//
// Point it at a real tree of six figures. One scavenge is ~1.8 MiB whatever the
// corpus, and the differences being looked for here are small.
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

import 'gc_ladder.dart';

const rungs = ['noop', 'io-stat', 'ffi-stat', 'ffi-fstatat', 'ffi-getdents'];

/// `struct stat` on Linux x86_64: 144 bytes, and the three fields SPEC §5.2
/// consumes sit at these offsets.
///
/// Hard-coded rather than derived, and checked at startup by [_assertStatLayout]
/// against what `dart:io` reports for a known file — a wrong offset here would
/// read plausible-looking garbage and quietly invalidate every FFI rung.
const _statBytes = 144;
const _stModeOffset = 24;
const _stSizeOffset = 48;
const _stMtimeSecOffset = 88;

const _sIfmt = 0xF000;
const _sIfdir = 0x4000;
const _sIfreg = 0x8000;

const _oRdonly = 0;
const _oDirectory = 0x10000;
const _atSymlinkNofollow = 0x100;

/// `struct linux_dirent64`: the name starts at 19 and is NUL-terminated.
const _dReclenOffset = 16;
const _dTypeOffset = 18;
const _dNameOffset = 19;

const _dtUnknown = 0;
const _dtDir = 4;
const _dtReg = 8;

/// How much one `getdents64` asks for. 64 KiB, so a large directory is a couple
/// of syscalls rather than dozens, and the buffer is allocated once per walk
/// rather than per directory.
const _direntBufferBytes = 64 * 1024;

Future<void> main(List<String> args) async {
  if (args.isNotEmpty && args.first == 'rung') {
    _runRung(args[1], args[2]);
    return;
  }

  final root = flagOf(args, '--root');
  if (root == null || !Directory(root).existsSync()) {
    stderr.writeln(
      'usage: dart run benchmark/dir_stat_probe.dart --root <dir> '
      '[--rung <name>]\nrungs: ${rungs.join(', ')}',
    );
    exitCode = 2;
    return;
  }
  if (!Platform.isLinux) {
    stderr.writeln('this probe is Linux-only — see its header');
    exitCode = 2;
    return;
  }

  final only = flagOf(args, '--rung');
  if (only != null && !rungs.contains(only)) {
    stderr.writeln('unknown rung: $only\nrungs: ${rungs.join(', ')}');
    exitCode = 2;
    return;
  }

  stdout.writeln('tree: $root');
  await runLadder(
    // The floor rung always runs: without it a one-rung run reports itself
    // as its own floor and prints zero.
    rungs: only == null ? rungs : [rungs.first, only],
    script: Platform.script.toFilePath(),
    rungArgs: [root],
  );
}

void _runRung(String rung, String root) {
  final counts = _Counts();
  final clock = Stopwatch()..start();
  switch (rung) {
    case 'noop':
      break;
    case 'io-stat':
      _walkIo(root, counts, _IoStatMode.dartIo);
    case 'ffi-stat':
      _assertStatLayout(root);
      _walkIo(root, counts, _IoStatMode.libcStat);
    case 'ffi-fstatat':
      _assertStatLayout(root);
      _walkIo(root, counts, _IoStatMode.libcFstatat);
    case 'ffi-getdents':
      _assertStatLayout(root);
      _walkGetdents(root, counts);
    default:
      throw ArgumentError('unknown rung: $rung');
  }
  clock.stop();
  stdout.writeln(
    RungResult(units: counts.files, millis: clock.elapsedMilliseconds),
  );
}

/// How a rung that uses `Directory.listSync` gets a file's metadata.
enum _IoStatMode { dartIo, libcStat, libcFstatat }

/// The three rungs that share `dart:io`'s listing.
///
/// One walker with a mode rather than three: three would drift apart, and a
/// ladder whose rungs list differently is not measuring the stat. The mode test
/// is an enum comparison per file, beneath the resolution of anything here —
/// `ScanProbe` makes the same trade for the same reason.
void _walkIo(String root, _Counts counts, _IoStatMode mode) {
  final buf = mode == _IoStatMode.dartIo ? nullptr : calloc<Uint8>(_statBytes);
  try {
    _walkIoInto(root, counts, mode, buf);
  } finally {
    if (buf != nullptr) calloc.free(buf);
  }
}

void _walkIoInto(
  String dir,
  _Counts counts,
  _IoStatMode mode,
  Pointer<Uint8> buf,
) {
  final List<FileSystemEntity> children;
  try {
    children = Directory(dir).listSync(followLinks: false);
  } on FileSystemException {
    // Cost, not correctness — the same silence `ScanProbe` keeps.
    return;
  }

  // Opened once per directory, and only by the rung that needs it: this is the
  // cost `ffi-fstatat` is trading path resolution for, so it has to be inside
  // the measured region and counted once per directory, not once per file.
  var dirfd = -1;
  if (mode == _IoStatMode.libcFstatat) {
    final native = dir.toNativeUtf8();
    try {
      dirfd = _open(native, _oRdonly | _oDirectory);
    } finally {
      malloc.free(native);
    }
    if (dirfd < 0) return;
  }

  try {
    for (final child in children) {
      if (child is Directory) {
        _walkIoInto(child.path, counts, mode, buf);
        continue;
      }
      if (child is! File) continue;
      counts.files++;
      switch (mode) {
        case _IoStatMode.dartIo:
          final stat = child.statSync();
          counts.fold(
            stat.mode,
            stat.size,
            stat.modified.millisecondsSinceEpoch ~/ 1000,
          );
        case _IoStatMode.libcStat:
          final native = child.path.toNativeUtf8();
          try {
            if (_stat(native, buf) == 0) counts.foldBuffer(buf);
          } finally {
            malloc.free(native);
          }
        case _IoStatMode.libcFstatat:
          // Only the last segment crosses to C, which is the whole point: the
          // kernel resolves one name against an open directory instead of every
          // component of an absolute path.
          final native = _basename(child.path).toNativeUtf8();
          try {
            if (_fstatat(dirfd, native, buf, 0) == 0) counts.foldBuffer(buf);
          } finally {
            malloc.free(native);
          }
      }
    }
  } finally {
    if (dirfd >= 0) _close(dirfd);
  }
}

/// The rung with no `dart:io` in it at all.
///
/// **No Dart string is built for a file.** `getdents64` leaves each name in the
/// buffer, NUL-terminated, which is exactly what `fstatat` wants — so the name
/// is handed over as a pointer into that buffer and never becomes a `String`.
/// Descending uses `openat` against the handle already held, so no path is
/// rebuilt for a directory either. That makes this rung the upper bound on what
/// leaving `dart:io` can buy, rather than one point inside it.
void _walkGetdents(String root, _Counts counts) {
  final statBuf = calloc<Uint8>(_statBytes);
  final dirBuf = calloc<Uint8>(_direntBufferBytes);
  final native = root.toNativeUtf8();
  final rootFd = _open(native, _oRdonly | _oDirectory);
  malloc.free(native);
  try {
    if (rootFd >= 0) _readDir(rootFd, counts, statBuf, dirBuf);
  } finally {
    if (rootFd >= 0) _close(rootFd);
    calloc.free(statBuf);
    calloc.free(dirBuf);
  }
}

/// Reads one directory by handle and recurses. [dirFd] is closed by the caller.
///
/// **The dirent buffer is shared down the recursion and that is not a bug**: a
/// child directory is only descended into *after* its entry has been read out of
/// the parent's buffer — the descent happens from a second pass over a small
/// list of names, not from inside the read. Sharing it is what keeps this rung's
/// memory one buffer rather than one per level.
void _readDir(
  int dirFd,
  _Counts counts,
  Pointer<Uint8> statBuf,
  Pointer<Uint8> dirBuf,
) {
  // Subdirectory names, copied out because the buffer is reused by the read
  // that would otherwise still be in progress when the descent happens.
  final subdirectories = <String>[];

  while (true) {
    final read = _getdents64(dirFd, dirBuf, _direntBufferBytes);
    if (read <= 0) break;
    var offset = 0;
    while (offset < read) {
      final entry = dirBuf + offset;
      final reclen = (entry + _dReclenOffset).cast<Uint16>().value;
      final type = (entry + _dTypeOffset).value;
      final name = (entry + _dNameOffset).cast<Utf8>();
      offset += reclen;

      if (_isDotEntry(entry + _dNameOffset)) continue;

      switch (type) {
        case _dtReg:
          counts.files++;
          if (_fstatat(dirFd, name, statBuf, 0) == 0) {
            counts.foldBuffer(statBuf);
          }
        case _dtDir:
          subdirectories.add(name.toDartString());
        case _dtUnknown:
          // Some filesystems do not fill `d_type`. One `fstatat` says what it
          // is, and for a file it is the same call the typed branch makes, so
          // only a directory costs an extra one.
          if (_fstatat(dirFd, name, statBuf, _atSymlinkNofollow) != 0) continue;
          final mode = (statBuf + _stModeOffset).cast<Uint32>().value;
          if (mode & _sIfmt == _sIfreg) {
            counts.files++;
            counts.foldBuffer(statBuf);
          } else if (mode & _sIfmt == _sIfdir) {
            subdirectories.add(name.toDartString());
          }
        default:
          // A symlink, socket, fifo or device. `Directory.list(followLinks:
          // false)` hands these to the scanner as neither a `File` nor a
          // `Directory` and it skips them, so they are skipped here too.
          break;
      }
    }
  }

  for (final name in subdirectories) {
    final native = name.toNativeUtf8();
    final childFd = _openat(dirFd, native, _oRdonly | _oDirectory);
    malloc.free(native);
    if (childFd < 0) continue;
    try {
      _readDir(childFd, counts, statBuf, dirBuf);
    } finally {
      _close(childFd);
    }
  }
}

/// Whether a dirent's name is `.` or `..`, tested on the bytes rather than by
/// building a `String` for every entry in the tree.
bool _isDotEntry(Pointer<Uint8> name) {
  if (name.value != 0x2E) return false;
  final second = (name + 1).value;
  return second == 0 || (second == 0x2E && (name + 2).value == 0);
}

/// The last segment of a `/`-separated path. Hand-written rather than
/// `package:path`'s `basename`, which parses the whole path into two lists to
/// return one segment — a cost commit 43204b0 already removed from the scanner
/// and which would land inside this rung's figure.
String _basename(String path) {
  final slash = path.lastIndexOf('/');
  return slash < 0 ? path : path.substring(slash + 1);
}

/// Checks the hard-coded `struct stat` offsets against what `dart:io` reports
/// for a file that is certainly there.
///
/// A wrong offset reads a neighbouring field, which looks like a plausible
/// number and would invalidate every FFI rung silently. This makes that a
/// startup failure instead.
void _assertStatLayout(String root) {
  final probe = File(Platform.script.toFilePath());
  final expected = probe.statSync();
  final buf = calloc<Uint8>(_statBytes);
  final native = probe.path.toNativeUtf8();
  try {
    if (_stat(native, buf) != 0) {
      throw StateError('libc stat failed on ${probe.path}');
    }
    final size = (buf + _stSizeOffset).cast<Int64>().value;
    final mode = (buf + _stModeOffset).cast<Uint32>().value & 0xFFF;
    if (size != expected.size || mode != (expected.mode & 0xFFF)) {
      throw StateError(
        'struct stat layout is not what this probe assumes: '
        'libc says size $size mode $mode, dart:io says '
        '${expected.size} ${expected.mode & 0xFFF}',
      );
    }
  } finally {
    malloc.free(native);
    calloc.free(buf);
  }
}

/// The tally each rung threads through itself. Folded fields are never read —
/// they exist so a rung genuinely consumes what it asked the kernel for.
class _Counts {
  int files = 0;
  int folded = 0;

  void fold(int mode, int size, int mtimeSeconds) {
    folded ^= mode & 0xFFF;
    folded ^= size;
    folded ^= mtimeSeconds;
  }

  void foldBuffer(Pointer<Uint8> buf) => fold(
    (buf + _stModeOffset).cast<Uint32>().value,
    (buf + _stSizeOffset).cast<Int64>().value,
    (buf + _stMtimeSecOffset).cast<Int64>().value,
  );
}

// `DynamicLibrary.process()` rather than a library file, for the reason
// `posix_chmod.dart` gives: these symbols are already in every process this runs
// in, and naming a file would mean naming a different one per platform.
final DynamicLibrary _libc = DynamicLibrary.process();

final _stat = _libc
    .lookupFunction<
      Int Function(Pointer<Utf8>, Pointer<Uint8>),
      int Function(Pointer<Utf8>, Pointer<Uint8>)
    >('stat');

final _fstatat = _libc
    .lookupFunction<
      Int Function(Int, Pointer<Utf8>, Pointer<Uint8>, Int),
      int Function(int, Pointer<Utf8>, Pointer<Uint8>, int)
    >('fstatat');

final _open = _libc
    .lookupFunction<
      Int Function(Pointer<Utf8>, Int),
      int Function(Pointer<Utf8>, int)
    >('open');

final _openat = _libc
    .lookupFunction<
      Int Function(Int, Pointer<Utf8>, Int),
      int Function(int, Pointer<Utf8>, int)
    >('openat');

final _close = _libc
    .lookupFunction<Int Function(Int), int Function(int)>('close');

final _getdents64 = _libc
    .lookupFunction<
      IntPtr Function(Int, Pointer<Uint8>, IntPtr),
      int Function(int, Pointer<Uint8>, int)
    >('getdents64');
