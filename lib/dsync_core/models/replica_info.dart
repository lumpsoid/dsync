/// What an [Agent] reports about its replica in reply to `hello` (SPEC
/// §4.2).
///
/// A named object rather than a bare `DateTime?` so a later field — the run
/// header (SPEC §11.4) is expected to want one — is an addition here, not
/// another change to `Agent.hello`'s return type.
class ReplicaInfo {
  /// The mtime of this replica's archive log file, or `null` if no commit
  /// has ever happened (SPEC §8.2). Carried in the reply because the
  /// initiator cannot `stat` an archive that lives on the remote host.
  final DateTime? lastCommitTime;

  const ReplicaInfo({this.lastCommitTime});
}
