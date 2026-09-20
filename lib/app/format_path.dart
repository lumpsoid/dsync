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
/// Known limitation: [maxLength] counts characters, not measured width, so
/// this is not the same elision a text painter would do — a wide font or a
/// narrow screen can still overflow, which is why callers keep
/// `TextOverflow.ellipsis` on as a backstop. Measuring needs a `TextPainter`
/// and therefore a widget test with a pumped frame; counting is a pure rule
/// testable with plain strings, and this project values that more (CLAUDE.md,
/// "Testable").
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
  if (budget <= 0) return last.substring(last.length - maxLength);
  return '$head${last.substring(last.length - budget)}';
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

  /// Everything above [leaf], elided and ending in `/` — the part two runs
  /// on the same device usually share.
  final String parent;

  /// The last segment, drawn whole.
  final String leaf;
}
