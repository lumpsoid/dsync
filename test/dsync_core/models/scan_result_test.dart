import 'package:dsync/dsync_core/models/scan_entry.dart';
import 'package:dsync/dsync_core/models/scan_result.dart';
import 'package:dsync/dsync_core/models/skipped_path.dart';
import 'package:test/test.dart';

void main() {
  group('ScanResult.reasonTally (SPEC §5.2, §11.4, task 1fd42b)', () {
    test('counts each entry by ScanReason, on plain values', () {
      final result = ScanResult(
        entries: const [
          ScanEntry(path: 'a.txt', reason: ScanReason.metadataMatched),
          ScanEntry(path: 'b.txt', reason: ScanReason.metadataMatched),
          ScanEntry(path: 'c.txt', reason: ScanReason.hashMatched),
          ScanEntry(path: 'd.txt', reason: ScanReason.modified),
          ScanEntry(path: 'e.txt', reason: ScanReason.created),
          ScanEntry.deleted('f.txt'),
        ],
      );

      final tally = result.reasonTally;
      expect(tally.metadataMatched, 2);
      expect(tally.hashMatched, 1);
      expect(tally.modified, 1);
      expect(tally.created, 1);
      expect(tally.deleted, 1);
      expect(tally.total, 6);
    });

    test('an empty scan tallies to all zeros', () {
      final tally = const ScanResult(entries: []).reasonTally;
      expect(tally.metadataMatched, 0);
      expect(tally.hashMatched, 0);
      expect(tally.modified, 0);
      expect(tally.created, 0);
      expect(tally.deleted, 0);
      expect(tally.total, 0);
    });

    test('metadataMatched and hashMatched are counted separately, even though '
        'both are ScanStatus.unchanged — the distinction this task exists to '
        'surface', () {
      final tally = const ScanResult(
        entries: [
          ScanEntry(path: 'a.txt', reason: ScanReason.metadataMatched),
          ScanEntry(path: 'b.txt', reason: ScanReason.hashMatched),
        ],
      ).reasonTally;

      expect(tally.metadataMatched, 1);
      expect(tally.hashMatched, 1);
    });
  });

  group('ScanResult.unreadableCount (SPEC §5, task 37bf4f)', () {
    test('counts only the paths the scan could not read, not the symlinks '
        'sharing the list: a skipped symlink is the tool obeying §9 and '
        'happens on every run, so counting it would put any tree with a '
        'symlink in it permanently on exit 1', () {
      const result = ScanResult(
        entries: [],
        skippedPaths: [
          SkippedPath.symlink('link.txt', 'no follow rule matched'),
          SkippedPath.symlink('other-link.txt', 'no follow rule matched'),
          SkippedPath.unreadable('locked.txt', 'Permission denied'),
        ],
      );

      expect(result.unreadableCount, 1);
    });

    test('a scan with nothing skipped counts zero', () {
      expect(const ScanResult(entries: []).unreadableCount, 0);
    });
  });
}
