/// How one side's scan divided across SPEC §5.2's branches.
final class ScanTally {
  const ScanTally({
    required this.metadataMatched,
    required this.hashMatched,
    required this.modified,
    required this.created,
    required this.deleted,
    required this.untrusted,
  });

  final int metadataMatched;
  final int hashMatched;
  final int modified;
  final int created;
  final int deleted;
  final int untrusted;
}
