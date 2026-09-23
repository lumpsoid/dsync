/// Whether a replica's root folder is there, as its own `Agent` found it
/// when answering `hello` (SPEC §4.5).
///
/// A fact, not a verdict: what a run does about a missing root is
/// `ReplicaInfo.mustCreateRoot`'s to decide, because that also needs to know
/// whether the replica has an archive.
sealed class ReplicaRoot {
  const ReplicaRoot();
}

class RootPresent extends ReplicaRoot {
  const RootPresent();
}

/// The root folder does not exist.
///
/// [archivedFiles] is how many files this replica's archive holds — what the
/// last sync saw there, and what a run over the missing folder would report
/// as deleted. Zero when there is no archive.
class RootMissing extends ReplicaRoot {
  final String rootPath;
  final int archivedFiles;

  const RootMissing({required this.rootPath, required this.archivedFiles});
}

/// A run refused a replica whose root folder is missing but whose archive
/// exists (SPEC §4.5): scanning an absent folder against that archive would
/// report every archived file as deleted, and the run would propagate those
/// deletions to the other side.
///
/// Raised on the initiator by `ReplicaInfo.mustCreateRoot`, from facts both
/// agents reported in `hello`, so it is the same typed failure for a local
/// replica and a remote one — nothing about it crosses the wire as text.
class MissingReplicaRootException implements Exception {
  /// Which side of the run is missing its root, so a head can name the
  /// device it is on.
  final bool onA;
  final String rootPath;
  final int archivedFiles;

  const MissingReplicaRootException({
    required this.onA,
    required this.rootPath,
    required this.archivedFiles,
  });

  /// The failure in the user's terms, naming the [device] the folder is on.
  String describeOn(String device) => _describe(' on $device');

  @override
  String toString() => _describe('');

  String _describe(String where) =>
      'The folder $rootPath$where is missing. If it is on a drive that is '
      'not mounted, reconnect it; the last sync saw $archivedFiles '
      '${archivedFiles == 1 ? 'file' : 'files'} there.';
}
