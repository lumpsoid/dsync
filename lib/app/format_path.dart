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
