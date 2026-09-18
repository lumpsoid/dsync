/// One rung of the ladder [ScanProbeReport] measures, in ascending order of
/// what it does per path (task 1a341e).
///
/// Every rung walks the whole tree doing what a named lower rung did plus one
/// named addition, so the difference between the two is the cost of that
/// addition and nothing else. That is the only reason this is an enum of
/// cumulative layers rather than a bag of independent timings: a figure for
/// "what `stat` costs" measured on its own would be measured against a walk
/// that never happened, while the same figure taken as a difference is
/// measured against the walk that did.
///
/// The report prints the derivation beside every figure rather than leaving
/// the reader to assume it came from the row above — SPEC §17's rule is that
/// a conclusion comes from a number the report shows, and a subtracted number
/// only qualifies if its two inputs are visible.
///
/// [list] and [stat] are the *platform's* floor: syscalls a walk of this tree
/// cannot avoid on this device. [rules] and above is this project's own code.
/// That split is the whole question task 1a341e asks, and it is a subtraction
/// between two rungs of this enum rather than anything the SPEC §17 report can
/// say, because §17 measures a run's phases (§13) and `scan` is one of them.
enum ScanProbeLayer {
  /// `Directory.list(followLinks: false)` per directory, recursing into the
  /// children the listing itself already types as directories, plus the
  /// walk's own sort.
  ///
  /// The sort is pure CPU and is included here — in the floor — rather than
  /// given a rung of its own, deliberately: it is part of the walk's shape
  /// at every rung above, so folding it in is what lets every *other* delta
  /// be a single named addition. It flatters the floor by however long
  /// sorting a few thousand short strings takes, and the report says so.
  list,

  /// [list] plus `FileStat` per file: the size and mtime SPEC §5.2's fast
  /// path compares, and the mode §7.4 propagates.
  ///
  /// Exactly what `Scanner._walkChildren` does — including its `stat`
  /// batching, at most `jobs` outstanding — and **the platform floor**: the
  /// syscalls a walk of this tree cannot avoid on this device. Everything
  /// above this rung is ours.
  ///
  /// There is no `FileSystemEntity.type` call in it because the scanner no
  /// longer makes one: the listing already types each child, and asking the
  /// OS again cost 3.50 s of a 29.9 s scan on a phone before task 1a341e
  /// removed it. A rung for that call would now be measuring code that does
  /// not exist, at the price of another full walk.
  stat,

  /// Adds SPEC §5.1's per-path decisions: the basename read back out of the
  /// OS-spelled path (§3), the root-relative path joined from it, the
  /// [RuleSet.ignores] match, and the §7.2 scratch-file check. No archive,
  /// no [ScanEntry], no hashing.
  rules,

  /// A real `Scanner.scan` against an archive that already matches the tree,
  /// so every file resolves on SPEC §5.2 step 1 and **nothing is hashed**.
  ///
  /// Against [rules] this buys the archive lookup per path, the [ScanEntry]
  /// and [ScanResult] construction, and the walk's own bookkeeping — the
  /// seen set, the deleted-path sweep, the §16 collision check.
  scanWarmArchive,

  /// A real `Scanner.scan` against an empty archive: the shape of a *first*
  /// sync, where SPEC §5.2 step 3 sends every file to SHA-256.
  ///
  /// Against [scanWarmArchive] this buys hashing and only hashing, which is
  /// the point of measuring both. The run task 1a341e is about was a first
  /// sync, so this is the rung comparable with its 36.7 s — and a reading of
  /// that number that did not separate this rung from the one below it would
  /// be attributing the tree's whole content to the walk.
  scanEmptyArchive,
}

/// What one [ScanProbeLayer] cost on one pass.
class ScanProbeLayerResult {
  final ScanProbeLayer layer;
  final Duration elapsed;

  /// Regular files the rung visited. Counted per rung rather than once for
  /// the tree, because a rung that disagrees with the others is a rung that
  /// did not walk the same thing, and a per-file rate derived from the wrong
  /// denominator is the failure mode SPEC §17 already names.
  final int files;

  /// Directories the rung traversed, or `null` for a rung that measures
  /// `Scanner.scan` — a [ScanResult] does not report how many directories the
  /// walk went through (SPEC §5.1: directories are traversed but never
  /// reported), and inventing the figure from a lower rung would be claiming
  /// this rung counted something it did not.
  final int? directories;

  /// Total size of the files this rung stat'd, or `0` for a rung that never
  /// stats and so never learns a size.
  final int bytes;

  const ScanProbeLayerResult({
    required this.layer,
    required this.elapsed,
    required this.files,
    required this.directories,
    this.bytes = 0,
  });

  /// Microseconds of this rung per file it visited.
  ///
  /// Derived, and the report labels it as such: it is the figure that says
  /// whether the cost is per-path at all, and it answers that only when the
  /// same rung is run against two roots of different sizes (task 1a341e's
  /// subset check). Read off a single root it is arithmetic, not evidence.
  double get microsPerFile => files == 0 ? 0 : elapsed.inMicroseconds / files;
}

/// What each rung of the walk actually does, as three plain questions rather
/// than as comparisons against [ScanProbeLayer]'s declaration order.
///
/// Declaration order is not a safe proxy for behaviour: an `index >=` test
/// would silently give a newly inserted rung whichever behaviour it happened
/// to be declared after. These say what they mean, so adding or removing a
/// rung cannot quietly change another one's walk — as it would have when the
/// `type` rung was dropped.
extension ScanProbeLayerWalk on ScanProbeLayer {
  /// Whether the rung stats each file.
  bool get statsFiles => this != ScanProbeLayer.list;


  /// Whether the rung builds root-relative paths and applies SPEC §5.1's
  /// per-path decisions to them.
  bool get appliesRules => switch (this) {
    ScanProbeLayer.rules ||
    ScanProbeLayer.scanWarmArchive ||
    ScanProbeLayer.scanEmptyArchive => true,
    _ => false,
  };
}

/// One full climb of the ladder over one tree.
///
/// Passes are run back to back over the same root so the second and later
/// ones read a warm page cache. A pass much faster than the first says the
/// cost is I/O; passes that are identical say it is CPU, and therefore code.
class ScanProbePass {
  /// Zero-based; pass 0 is the only one whose cache state is whatever the
  /// device happened to be in when the probe started.
  final int index;

  final List<ScanProbeLayerResult> layers;

  const ScanProbePass({required this.index, required this.layers});

  ScanProbeLayerResult? operator [](ScanProbeLayer layer) {
    for (final result in layers) {
      if (result.layer == layer) return result;
    }
    return null;
  }
}

/// What a [ScanProbe] measured: the same ladder climbed [passes] times over
/// one replica root (task 1a341e).
class ScanProbeReport {
  /// The root as the probe resolved it — symlinks followed, the way
  /// `Scanner.scan` resolves its own root — not as it was typed.
  final String rootPath;

  final List<ScanProbePass> passes;

  const ScanProbeReport({required this.rootPath, required this.passes});
}
