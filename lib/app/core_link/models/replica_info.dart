/// A side's `hello` reply, for the run header.
final class ReplicaInfo {
  const ReplicaInfo({
    required this.lastCommit,
    required this.archivePath,
    required this.missingRoot,
  });

  /// `null`: this side has never committed (a first sync).
  final DateTime? lastCommit;
  final String? archivePath;

  /// The root folder is missing: its path and how many files the last
  /// sync saw there (SPEC §4.5).
  final ({String path, int archivedFiles})? missingRoot;
}
