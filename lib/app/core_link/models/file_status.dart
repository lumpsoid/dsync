/// One side's status for a path (SPEC §5.2).
sealed class FileStatus {
  const FileStatus();
}

/// A file present on disk: its size and mtime (µs since the epoch).
typedef FileFacts = ({int size, int mtimeUs});

final class StatusUnchanged extends FileStatus {
  const StatusUnchanged(this.file, {required this.byHash});

  final FileFacts file;
  final bool byHash;
}

final class StatusCreated extends FileStatus {
  const StatusCreated(this.file);

  final FileFacts file;
}

final class StatusModified extends FileStatus {
  const StatusModified(this.file);

  final FileFacts file;
}

final class StatusDeleted extends FileStatus {
  const StatusDeleted();
}

/// A write that never committed (SPEC §7.6).
final class StatusUntrusted extends FileStatus {
  const StatusUntrusted(this.file);

  final FileFacts file;
}

final class StatusUntrustedAbsent extends FileStatus {
  const StatusUntrustedAbsent();
}
