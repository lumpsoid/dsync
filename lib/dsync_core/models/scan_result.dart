import 'package:dsync/dsync_core/models/scan_entry.dart';

/// Everything one replica's scan found (SPEC §5).
///
/// [entries] is what reconciliation consumes. [skippedSymlinks] carries the
/// rest of §5.1's requirement — symlinks are "skipped **and reported**" —
/// which has nowhere to live in a [ScanEntry]: a skipped link has no status
/// relative to the archive, and giving it one would drag it into the §6
/// table, where every cell would have to say "do nothing".
class ScanResult {
  final List<ScanEntry> entries;

  /// Root-relative paths of symlinks the scan did not follow, because no
  /// `follow` rule matched or because the link was broken (SPEC §5.1, §9).
  final List<String> skippedSymlinks;

  const ScanResult({required this.entries, this.skippedSymlinks = const []});
}
