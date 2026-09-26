/// How one side's scan divided across SPEC §5.2's branches, and what the
/// core counts them to: every path it checked ([total]) and every one it
/// did not find unchanged ([changed]).
final class ScanTally {
  const ScanTally({
    required this.metadataMatched,
    required this.hashMatched,
    required this.modified,
    required this.created,
    required this.deleted,
    required this.untrusted,
    required this.total,
    required this.changed,
  });

  final int metadataMatched;
  final int hashMatched;
  final int modified;
  final int created;
  final int deleted;
  final int untrusted;
  final int total;
  final int changed;
}
