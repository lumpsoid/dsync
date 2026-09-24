import 'replica_side.dart';

/// One archive log in this host's state directory (SPEC §8.3).
final class ArchiveInfo {
  const ArchiveInfo({
    required this.logPath,
    required this.profileId,
    required this.side,
    required this.rootPath,
    required this.sizeBytes,
    required this.lastModified,
  });

  final String logPath;
  final String profileId;
  final ReplicaSide side;

  /// `null`: the first line is not a readable header.
  final String? rootPath;
  final int sizeBytes;
  final DateTime lastModified;
}
