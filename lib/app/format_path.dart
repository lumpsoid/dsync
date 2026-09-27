/// A filesystem path shortened for a one-line label, with the *middle*
/// taken out rather than the end.
///
/// `TextOverflow.ellipsis` clips the tail, which is the worst possible cut
/// for a path: every folder on an Android device shares the same long
/// prefix (`/storage/emulated/0/Android/data/…`), so tail-clipping shows
/// the part that is identical for every row and hides the leaf — the only
/// part that tells two saved runs apart. This keeps the root marker (`/`,
/// `~/`, or nothing for a relative path) so the reader can still see what
/// kind of path it is, drops whole segments out of the middle, and spends
/// the rest of the budget on as many trailing segments as fit:
/// `/storage/…/dsync/notes`.
///
/// Segment-aligned on purpose — cutting mid-segment reads as a typo, while
/// a dropped segment reads as "there is more here". A single segment too
/// long to fit is the one case that must be cut mid-word, and it is cut
/// from its left, again to keep the end.
///
/// [maxLength] counts characters, not measured width. A label on screen is
/// shortened by [elidePathToFit], which searches this function's budgets
/// against the width the label actually has; a character count on its own
/// is what the Run review's stacked parent line still uses
/// ([PathLabel.stacked]).
String elidePath(String path, {int maxLength = defaultPathLabelLength}) {
  if (path.length <= maxLength) return path;
  final marker = path.startsWith('~/')
      ? '~/'
      : path.startsWith('/')
      ? '/'
      : '';
  final segments = path
      .substring(marker.length)
      .split('/')
      .where((segment) => segment.isNotEmpty)
      .toList();
  final head = '$marker…/';
  var tail = '';
  for (var i = segments.length - 1; i >= 0; i--) {
    final wider = tail.isEmpty ? segments[i] : '${segments[i]}/$tail';
    if (head.length + wider.length > maxLength) break;
    tail = wider;
  }
  if (tail.isNotEmpty) return '$head$tail';

  // Not even the last segment fits beside the marker: keep its end.
  final last = segments.isEmpty ? path : segments.last;
  final budget = maxLength - head.length;
  // Too narrow for the marker: the leaf's end alone, or the whole leaf when
  // it is shorter than the budget (the marker is what did not fit).
  if (budget <= 0) {
    return last.length <= maxLength
        ? last
        : last.substring(last.length - maxLength);
  }
  return '$head${last.substring(last.length - budget)}';
}

/// The longest form of [path] that [fits] accepts: [path] itself when it
/// fits whole, otherwise [elidePath] at the widest character budget whose
/// label still fits.
///
/// **Shortened only when the room requires it.** A fixed budget cuts a path
/// on a wide window that had space for all of it and still overflows a
/// narrow one; asking [fits] — in the app, "does this lay out in the width
/// the label has" (`PathText`) — cuts exactly as much as the space takes.
/// The elision itself stays [elidePath]'s, so a measured label keeps the
/// same shape as every other: the root marker, whole segments dropped from
/// the middle, and the leaf kept for as long as any of it can be.
///
/// **A binary search over the budget**, so a label costs about log₂ of its
/// length in [fits] calls rather than one per character — a measured call
/// is a text layout, and a list builds a label per row it scrolls in. The
/// search relies on [elidePath] growing with its budget (a wider budget
/// never yields a shorter label), which holds by construction: every extra
/// character either lengthens the cut leaf or admits one more segment.
///
/// When not even a one-character budget fits, the answer is the empty
/// string: there is no honest shorter path to draw.
String elidePathToFit(String path, bool Function(String label) fits) {
  if (fits(path)) return path;
  // [fitting] fits (or is the empty budget); [tooWide] does not.
  var fitting = 0;
  var tooWide = path.length;
  while (tooWide - fitting > 1) {
    final budget = (fitting + tooWide) ~/ 2;
    if (fits(elidePath(path, maxLength: budget))) {
      fitting = budget;
    } else {
      tooWide = budget;
    }
  }
  return elidePath(path, maxLength: fitting);
}

/// How long a path label may be before [elidePath] takes its middle out.
///
/// Named rather than inlined per call site so the profile list and the
/// archive list elide alike — two rows cut to different lengths on the same
/// screen read as a rendering bug. Sized for the subtitle line of a
/// `ListTile` on a phone at the default text scale.
const int defaultPathLabelLength = 40;

/// A path split into the part that distinguishes it and the part that does
/// not: [leaf], the last segment, and [parent], everything above it.
///
/// [elidePath] shortens a path into *one* string, which forces one text
/// weight on the whole of it — and a row that prints the shared prefix at
/// the same weight as the leaf reads as a wall of `/storage/emulated/0/…`.
/// Split, a caller can draw the parent quiet and the leaf loud, and can let
/// the parent give way on a narrow screen while the leaf stays whole: the
/// leaf is the only part that tells two saved runs apart, so it is the part
/// that must never be the one clipped.
///
/// [parent] keeps its trailing `/` so that parent and leaf drawn side by
/// side read as the one path they are, and carries the root marker (`/`,
/// `~/`, or nothing) like [elidePath] does. It is empty only for a path
/// with no segment above the leaf.
class PathLabel {
  const PathLabel({required this.parent, required this.leaf});

  /// [path] split, with [parent] middle-elided into whatever [maxLength]
  /// leaves once [leaf] has taken its share. The leaf is never shortened:
  /// a leaf wider than the whole budget leaves the parent a bare `…/`, and
  /// the caller's `TextOverflow.ellipsis` is what finally cuts it.
  factory PathLabel.of(String path, {int maxLength = defaultPathLabelLength}) {
    final marker = path.startsWith('~/')
        ? '~/'
        : path.startsWith('/')
        ? '/'
        : '';
    final segments = path
        .substring(marker.length)
        .split('/')
        .where((segment) => segment.isNotEmpty)
        .toList();
    if (segments.isEmpty) return PathLabel(parent: '', leaf: path);
    final leaf = segments.last;
    if (segments.length == 1) return PathLabel(parent: marker, leaf: leaf);

    final joined = '$marker${segments.take(segments.length - 1).join('/')}';
    // The `/` the parent ends with is part of what the budget pays for, so
    // the pair as drawn stays inside [maxLength].
    final budget = maxLength - leaf.length - 1;
    if (budget < marker.length + 2) {
      return PathLabel(parent: '$marker…/', leaf: leaf);
    }
    final parent = joined.length <= budget
        ? joined
        : elidePath(joined, maxLength: budget);
    return PathLabel(parent: '$parent/', leaf: leaf);
  }

  /// [path] split for a layout that stacks the two on separate lines — the
  /// leaf on its own line, wrapping, the parent on the line under it: the
  /// parent then has a line of its own to fill, so it is middle-elided
  /// into the whole of [maxLength] rather than whatever the leaf left.
  factory PathLabel.stacked(
    String path, {
    int maxLength = defaultPathLabelLength,
  }) {
    final whole = PathLabel.of(path, maxLength: path.length);
    if (whole.parent.length <= 1) return whole;
    final folder = whole.parent.substring(0, whole.parent.length - 1);
    return PathLabel(
      parent: '${elidePath(folder, maxLength: maxLength - 1)}/',
      leaf: whole.leaf,
    );
  }

  /// Everything above [leaf], elided and ending in `/` — the part two runs
  /// on the same device usually share.
  final String parent;

  /// The last segment, drawn whole.
  final String leaf;
}
