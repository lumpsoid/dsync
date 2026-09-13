/// The size, mtime, and mode actually observed for a file after a write
/// (SPEC §7.2 step 4, §7.4).
///
/// May differ from what was requested: mtime is always propagated but a
/// setter failure is non-fatal, and mode bits are best-effort. Callers
/// archive this actual state, never the intended one.
class FileMetadata {
  final int size;

  /// Microseconds since epoch, as returned by `FileStat` (SPEC §5.2).
  final int mtime;
  final int mode;

  const FileMetadata({
    required this.size,
    required this.mtime,
    required this.mode,
  });
}
