import 'dart:ffi';

import 'package:dsync/dsync_core/models/write_target.dart';
import 'package:ffi/ffi.dart';

/// Reads what is at [nativePath] before a copy writes it (SPEC §7.2).
///
/// Takes a **native** path, like [Chmod], because it goes straight to the
/// C library. Follows symlinks: a copy onto a followed link writes its
/// target (§5.1), so the target's facts are the ones that matter.
typedef ProbeWriteTarget = WriteTarget Function(String nativePath);

/// [ProbeWriteTarget] through `dart:ffi` — the default.
///
/// **Why FFI.** `dart:io`'s `FileStat` has no link count, and its `mode`
/// says what the bits are, not whether *this* process may write — so
/// neither fact is reachable from Dart. POSIX asks `stat(2)` for the
/// count and `access(2)` for writability; Windows asks
/// `GetFileInformationByHandle` for both.
///
/// **What it costs.** Two syscalls per copied file, measured at 11–15 µs
/// each on the phone's storage, against a write of several milliseconds
/// (tasks 203cfd, a4daa6). A path with nothing there yet fails the first
/// one and stops.
///
/// **`struct stat` has no portable layout**, so the link count's offset is
/// named per ABI below, and an ABI not named there reads as
/// [UnknownWriteTarget], which replaces rather than writes in place. So
/// does a C library without the symbol — glibc before 2.33 exports `stat`
/// only as `__xstat` — at the cost of the in-place write's speed, never
/// its safety.
WriteTarget probeWriteTarget(String nativePath) {
  final probe = _probe ??= _resolve();
  return probe(nativePath);
}

/// Resolved once and remembered, failure included: unlike `chmod`, whose
/// caller latches, an unavailable probe has one answer for every path.
ProbeWriteTarget? _probe;

ProbeWriteTarget _resolve() {
  if (Abi.current() == Abi.windowsX64 || Abi.current() == Abi.windowsArm64) {
    return _resolveWindows();
  }
  final layout = _statLayouts[Abi.current()];
  if (layout == null) {
    final reason = 'no struct stat layout for ${Abi.current()}';
    return (_) => UnknownWriteTarget(reason);
  }
  try {
    final libc = DynamicLibrary.process();
    final stat = libc.lookupFunction<_StatNative, _StatDart>(layout.symbol);
    final access = libc.lookupFunction<_AccessNative, _AccessDart>('access');
    return (nativePath) => _probePosix(nativePath, layout, stat, access);
  } on Object catch (error) {
    final reason = '$error';
    return (_) => UnknownWriteTarget(reason);
  }
}

/// Where `st_nlink` sits in this ABI's `struct stat`, and how wide it is.
typedef _StatLayout = ({String symbol, int nlinkOffset, int nlinkBytes});

/// Linux x86_64 (glibc and bionic alike) puts a 64-bit `st_nlink` straight
/// after `st_ino`; the generic 64-bit layout (arm64, riscv64) puts a 32-bit
/// one after `st_mode`, and bionic's 32-bit `stat64` body lands on the same
/// offset. macOS and iOS use the 64-bit-inode `struct stat`, whose symbol is
/// `stat$INODE64` on x86_64 and plain `stat` on arm64.
final Map<Abi, _StatLayout> _statLayouts = {
  Abi.linuxX64: (symbol: 'stat', nlinkOffset: 16, nlinkBytes: 8),
  Abi.androidX64: (symbol: 'stat', nlinkOffset: 16, nlinkBytes: 8),
  Abi.linuxArm64: (symbol: 'stat', nlinkOffset: 20, nlinkBytes: 4),
  Abi.linuxRiscv64: (symbol: 'stat', nlinkOffset: 20, nlinkBytes: 4),
  Abi.androidArm64: (symbol: 'stat', nlinkOffset: 20, nlinkBytes: 4),
  Abi.androidRiscv64: (symbol: 'stat', nlinkOffset: 20, nlinkBytes: 4),
  Abi.androidArm: (symbol: 'stat', nlinkOffset: 20, nlinkBytes: 4),
  Abi.androidIA32: (symbol: 'stat', nlinkOffset: 20, nlinkBytes: 4),
  Abi.macosArm64: (symbol: 'stat', nlinkOffset: 6, nlinkBytes: 2),
  Abi.iosArm64: (symbol: 'stat', nlinkOffset: 6, nlinkBytes: 2),
  Abi.macosX64: (symbol: r'stat$INODE64', nlinkOffset: 6, nlinkBytes: 2),
  Abi.iosX64: (symbol: r'stat$INODE64', nlinkOffset: 6, nlinkBytes: 2),
};

/// Larger than any `struct stat` above (144 bytes on Linux x86_64), so the
/// call never writes past the buffer whatever the ABI adds at the end.
const _statBufferBytes = 256;

/// `W_OK` on every POSIX host this runs on.
const _writeOk = 2;

typedef _StatNative = Int Function(Pointer<Utf8>, Pointer<Uint8>);
typedef _StatDart = int Function(Pointer<Utf8>, Pointer<Uint8>);
typedef _AccessNative = Int Function(Pointer<Utf8>, Int);
typedef _AccessDart = int Function(Pointer<Utf8>, int);

WriteTarget _probePosix(
  String nativePath,
  _StatLayout layout,
  _StatDart stat,
  _AccessDart access,
) {
  final path = nativePath.toNativeUtf8();
  final buffer = calloc<Uint8>(_statBufferBytes);
  try {
    // A failed stat is read as "nothing there" without asking errno, which
    // `dart:ffi` cannot read reliably. Nothing there is the common case;
    // every other failure (a missing search permission, a parent that is a
    // file, a link loop) fails the write that follows just the same.
    if (stat(path, buffer) != 0) return const AbsentWriteTarget();
    final at = buffer + layout.nlinkOffset;
    final linkCount = switch (layout.nlinkBytes) {
      8 => at.cast<Uint64>().value,
      4 => at.cast<Uint32>().value,
      _ => at.cast<Uint16>().value,
    };
    return ExistingWriteTarget(
      linkCount: linkCount,
      writable: access(path, _writeOk) == 0,
    );
  } finally {
    calloc.free(buffer);
    malloc.free(path);
  }
}

typedef _CreateFileNative = IntPtr Function(
  Pointer<Utf16>,
  Uint32,
  Uint32,
  Pointer<Void>,
  Uint32,
  Uint32,
  IntPtr,
);
typedef _CreateFileDart = int Function(
  Pointer<Utf16>,
  int,
  int,
  Pointer<Void>,
  int,
  int,
  int,
);
typedef _GetInfoNative = Int32 Function(IntPtr, Pointer<Uint8>);
typedef _GetInfoDart = int Function(int, Pointer<Uint8>);
typedef _CloseHandleNative = Int32 Function(IntPtr);
typedef _CloseHandleDart = int Function(int);

/// `FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE`: a handle that
/// asks for no access must still not lock anyone else out.
const _shareAll = 7;
const _openExisting = 3;

/// Lets `CreateFileW` open a directory too, so a directory at the target
/// reads as existing instead of absent.
const _backupSemantics = 0x02000000;
const _invalidHandle = -1;

/// `BY_HANDLE_FILE_INFORMATION`: attributes at 0, `nNumberOfLinks` at 40,
/// 52 bytes in all.
const _infoBytes = 52;
const _linkCountOffset = 40;
const _readOnlyAttribute = 1;

ProbeWriteTarget _resolveWindows() {
  try {
    final kernel32 = DynamicLibrary.open('kernel32.dll');
    final createFile = kernel32
        .lookupFunction<_CreateFileNative, _CreateFileDart>('CreateFileW');
    final getInfo = kernel32.lookupFunction<_GetInfoNative, _GetInfoDart>(
      'GetFileInformationByHandle',
    );
    final closeHandle = kernel32
        .lookupFunction<_CloseHandleNative, _CloseHandleDart>('CloseHandle');
    return (nativePath) =>
        _probeWindows(nativePath, createFile, getInfo, closeHandle);
  } on Object catch (error) {
    final reason = '$error';
    return (_) => UnknownWriteTarget(reason);
  }
}

WriteTarget _probeWindows(
  String nativePath,
  _CreateFileDart createFile,
  _GetInfoDart getInfo,
  _CloseHandleDart closeHandle,
) {
  final path = nativePath.toNativeUtf16();
  final info = calloc<Uint8>(_infoBytes);
  try {
    // Access 0 asks for metadata only, so a read-only or in-use file still
    // opens. Without FILE_FLAG_OPEN_REPARSE_POINT a symlink is followed.
    final handle = createFile(
      path,
      0,
      _shareAll,
      nullptr,
      _openExisting,
      _backupSemantics,
      0,
    );
    if (handle == _invalidHandle) return const AbsentWriteTarget();
    try {
      if (getInfo(handle, info) == 0) {
        return const UnknownWriteTarget('GetFileInformationByHandle failed');
      }
    } finally {
      closeHandle(handle);
    }
    final attributes = info.cast<Uint32>().value;
    return ExistingWriteTarget(
      linkCount: (info + _linkCountOffset).cast<Uint32>().value,
      writable: attributes & _readOnlyAttribute == 0,
    );
  } finally {
    calloc.free(info);
    malloc.free(path);
  }
}
