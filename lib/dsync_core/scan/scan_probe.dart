import 'dart:io';

import 'package:dsync/dsync_core/models/archive.dart';
import 'package:dsync/dsync_core/models/rule_set.dart';
import 'package:dsync/dsync_core/models/scan_entry.dart';
import 'package:dsync/dsync_core/models/scan_probe_report.dart';
import 'package:dsync/dsync_core/scan/scanner.dart';
import 'package:dsync/dsync_core/temp_file.dart';
import 'package:path/path.dart' as p;

/// Splits what a [Scanner] run costs into the platform's floor and this
/// project's own code, by walking one tree several times and adding one
/// named step per walk (task 1a341e).
///
/// **Why it exists.** SPEC §17 measures `scan` as one §13 phase, so it can
/// say the phase took 36.7 s and nothing about where those seconds went. The
/// split that question needs is *inside* the scan, and §17's phase list is
/// deliberately §13's flow and nothing else — see [RunPhase]'s own doc
/// comment. So it lives here, outside the run, and no run is instrumented to
/// produce it.
///
/// **Instrumentation, not a feature.** Nothing in the engine calls this; it
/// is reached from a head that is measuring. It is in `dsync_core` rather
/// than in a head or a `benchmark/` script for one reason: the device whose
/// cost profile exists nowhere else is a phone, and a figure measured by a
/// desktop script over a desktop filesystem cannot stand in for one. A
/// laptop differs from a phone in CPU *and* storage *and* OS at once, so the
/// comparison that settles anything is same-tree, same-device, and this has
/// to be runnable on the device to make it.
///
/// **What it does not do.** It reports no failures and fixes nothing: an
/// unreadable directory is skipped silently here, where [Scanner.scan] would
/// record it (SPEC §5). Correctness is the scanner's job and is tested
/// against the scanner; this measures cost, and a rung that stopped to build
/// a [SkippedPath] would be measuring something the rung below it did not.
class ScanProbe {
  /// Hashing concurrency handed to the [Scanner] the top two rungs measure,
  /// so those rungs are the real thing at the parallelism a run would use
  /// (SPEC §5.2) rather than a differently-configured lookalike.
  final int jobs;

  /// SPEC §3's read-side conversion, exactly as [Scanner] takes it and for
  /// exactly the same reason — see that class's own `pathStyle` doc comment.
  /// The [ScanProbeLayer.rules] rung does this conversion per entry, so a
  /// rung measured with the wrong style would be measuring different work
  /// from the scanner it is being subtracted from.
  final p.Style? pathStyle;

  /// SPEC §16's collision key, exactly as [Scanner] takes it — and supplied
  /// here for the same reason [jobs] is: a real run resolves this once per
  /// replica by probing the filesystem (`case_folding.dart`'s
  /// `detectsCaseFolding`) and hands it to its scanner, so a probe that left
  /// it `null` would measure a scanner doing strictly less work than the one
  /// whose 36.7 s is being explained. The check's cost lands in the
  /// difference between the [ScanProbeLayer.scanWarmArchive] rung and the
  /// [ScanProbeLayer.rules] rung below it, which is why that step is named
  /// for §16 as well as for the archive.
  final String Function(String path)? foldKey;

  final p.Context _pathContext;

  ScanProbe({this.jobs = 4, this.pathStyle, this.foldKey})
    : _pathContext = p.Context(style: pathStyle ?? p.Style.posix);

  /// Climbs [ScanProbeLayer]'s ladder over [rootPath], [passes] times.
  ///
  /// Passes run back to back on purpose (task 1a341e): a second pass much
  /// faster than the first says the cost is I/O and page cache, and one that
  /// matches it says the cost is CPU and therefore code. Nothing here drops
  /// the cache between them — that needs root on Android — so pass 0 is
  /// "whatever state the device was already in" and every later pass is
  /// warm. The comparison is still the one worth having; the report just
  /// must not be read as a cold/warm measurement in the other direction.
  ///
  /// [rules] should be the same [RuleSet] the real run uses (SPEC §9): the
  /// rung that measures rule matching is measuring *these* patterns against
  /// this tree, and an empty set would put that rung's cost at zero and
  /// attribute the difference to the scanner instead.
  Future<ScanProbeReport> run({
    required String rootPath,
    RuleSet? rules,
    int passes = 2,
  }) async {
    // Resolved the way `Scanner.scan` resolves its own root, so every rung
    // and the scanner rungs in particular walk the identical tree.
    final root = await Directory(rootPath).resolveSymbolicLinks();
    final ruleSet = rules ?? RuleSet();
    final scanner = Scanner(jobs: jobs, pathStyle: pathStyle, foldKey: foldKey);

    return ScanProbeReport(
      rootPath: root,
      passes: [
        for (var index = 0; index < passes; index++)
          await _pass(index, root, ruleSet, scanner),
      ],
    );
  }

  Future<ScanProbePass> _pass(
    int index,
    String root,
    RuleSet rules,
    Scanner scanner,
  ) async {
    final layers = <ScanProbeLayerResult>[
      for (final layer in const [
        ScanProbeLayer.list,
        ScanProbeLayer.stat,
        ScanProbeLayer.rules,
      ])
        await _walkLayer(layer, root, rules),
    ];

    // The empty-archive rung runs before the warm-archive one because it is
    // what *produces* the warm archive: the entries it reports are, by
    // construction, exactly what a committed archive would hold for this
    // tree, so the rung below it resolves every file on SPEC §5.2 step 1 and
    // hashes nothing. Building that archive from the filesystem separately
    // would be asserting the fast path matches rather than using the scan
    // that just proved it.
    final empty = _archiveFor(root, const {});
    final clock = Stopwatch()..start();
    final cold = await scanner.scan(
      rootPath: root,
      archive: empty,
      rules: rules,
    );
    clock.stop();
    layers.add(
      ScanProbeLayerResult(
        layer: ScanProbeLayer.scanEmptyArchive,
        elapsed: clock.elapsed,
        files: _livePaths(cold.entries).length,
        directories: null,
        bytes: _liveBytes(cold.entries),
      ),
    );

    final warm = _archiveFor(root, _archiveEntriesFrom(cold.entries));
    final warmClock = Stopwatch()..start();
    final warmResult = await scanner.scan(
      rootPath: root,
      archive: warm,
      rules: rules,
    );
    warmClock.stop();
    layers.add(
      ScanProbeLayerResult(
        layer: ScanProbeLayer.scanWarmArchive,
        elapsed: warmClock.elapsed,
        files: _livePaths(warmResult.entries).length,
        directories: null,
        bytes: _liveBytes(warmResult.entries),
      ),
    );

    return ScanProbePass(index: index, layers: layers);
  }

  Future<ScanProbeLayerResult> _walkLayer(
    ScanProbeLayer layer,
    String root,
    RuleSet rules,
  ) async {
    final counts = _ProbeCounts();
    final clock = Stopwatch()..start();
    await _walk(Directory(root), '', layer, rules, counts);
    clock.stop();
    return ScanProbeLayerResult(
      layer: layer,
      elapsed: clock.elapsed,
      files: counts.files,
      directories: counts.directories,
      bytes: counts.bytes,
    );
  }

  /// The body of every rung below [ScanProbeLayer.scanWarmArchive], shaped
  /// deliberately like `Scanner._walkChildren` so the subtraction against the
  /// scanner rungs is between two walks of the same shape.
  ///
  /// One method with rung tests rather than four walkers: four would drift
  /// apart, and a ladder whose rungs do subtly different walks measures
  /// nothing. The tests themselves are integer comparisons against an enum
  /// index, which is beneath the resolution of anything being measured here.
  Future<void> _walk(
    Directory dir,
    String relativePrefix,
    ScanProbeLayer layer,
    RuleSet rules,
    _ProbeCounts counts,
  ) async {
    final List<FileSystemEntity> children;
    try {
      children = await dir.list(followLinks: false).toList();
    } on FileSystemException {
      // Cost, not correctness — see the class doc comment.
      return;
    }
    children.sort((a, b) => a.path.compareTo(b.path));

    // Only [ScanProbeLayer.statConcurrent] fills this: the files of this one
    // directory, held back so their stats can be issued together below.
    final pending = <File>[];

    for (final child in children) {
      var relativePath = '';
      if (layer.appliesRules) {
        final name = _pathContext.basename(child.path);
        relativePath = relativePrefix.isEmpty ? name : '$relativePrefix/$name';
        if (rules.ignores(relativePath)) continue;
        if (isTempFileName(name)) continue;
      }

      // The child's type comes from the listing, which already typed it —
      // the same shape `Scanner._walkChildren` has, and the reason these
      // rungs are the floor rather than a walk with a syscall of their own.
      switch (child) {
        case Directory():
          counts.directories++;
          await _walk(child, relativePath, layer, rules, counts);
        case File():
          counts.files++;
          if (layer.statsFiles) pending.add(child);
        default:
          break;
      }
    }

    // One directory's stats issued together, at most [jobs] outstanding —
    // the same batching `Scanner._walkChildren` does, so the rung below the
    // scanner rungs walks the way the scanner walks.
    for (var start = 0; start < pending.length; start += jobs) {
      final batch = pending.sublist(
        start,
        (start + jobs).clamp(0, pending.length),
      );
      await Future.wait([for (final file in batch) _statInto(file, counts)]);
    }
  }

  /// Stats [file] and folds the result into [counts].
  ///
  /// The fields are read back rather than discarded: they are the three SPEC
  /// §5.2 and §7.4 actually consume, and a rung that threw the result away
  /// would be measuring a `stat` no caller wants.
  Future<void> _statInto(File file, _ProbeCounts counts) async {
    final stat = await file.stat();
    counts.bytes += stat.size;
    counts.mtimeMicros ^= stat.modified.microsecondsSinceEpoch;
    counts.modeBits ^= stat.mode & 0xFFF;
  }

  /// The archive shell the two scanner rungs compare against.
  ///
  /// Its header names this root and a probe-specific profile id: nothing
  /// reads it back and nothing writes it to disk (SPEC §8.3), so it exists
  /// only because [Archive] cannot be built without one.
  Archive _archiveFor(String root, Map<String, ArchiveEntry> entries) =>
      Archive(
        header: ArchiveHeader(
          schemaVersion: 1,
          profileId: 'scan-probe',
          rootPath: root,
        ),
        entries: entries,
      );

  /// The committed archive the [ScanProbeLayer.scanWarmArchive] rung reads —
  /// every live entry of the scan that just ran, with the size, mtime, mode
  /// and hash it reported, which is what SPEC §7.3 would have committed.
  Map<String, ArchiveEntry> _archiveEntriesFrom(List<ScanEntry> entries) => {
    for (final entry in _livePaths(entries))
      entry.path: ArchiveEntry(
        path: entry.path,
        size: entry.size!,
        mtime: entry.mtime!,
        mode: entry.mode!,
        hash: entry.hash!,
      ),
  };

  /// The entries that describe a file still on disk. A `deleted` entry
  /// (SPEC §5.2 step 4) carries no size, mtime, mode or hash and is not a
  /// file this walk visited, so it belongs in neither the archive built above
  /// nor the per-rung file count the report divides by.
  Iterable<ScanEntry> _livePaths(List<ScanEntry> entries) =>
      entries.where((e) => e.status != ScanStatus.deleted);

  int _liveBytes(List<ScanEntry> entries) =>
      _livePaths(entries).fold(0, (sum, e) => sum + e.size!);
}

/// What one rung's walk saw. Mutable and private: it is a tally the recursion
/// threads through itself, not a value anything outside this file holds.
class _ProbeCounts {
  int files = 0;
  int directories = 0;
  int bytes = 0;

  /// Folded-together `stat` fields, never read. They exist so the
  /// [ScanProbeLayer.stat] rung genuinely consumes what it asked the OS for;
  /// XOR because it is the cheapest fold that touches every value and cannot
  /// overflow into a different cost profile the way a running sum of
  /// microsecond timestamps would.
  int mtimeMicros = 0;
  int modeBits = 0;
}
