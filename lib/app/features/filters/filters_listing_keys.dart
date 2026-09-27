import 'package:flutter/services.dart';

import 'filters_view_state.dart';

/// What a key does to the folder listing — the listing's keyboard, as
/// plain values: the page turns a key into one of these with
/// [ListingCommand.forKey] and only carries it out.
sealed class ListingCommand {
  const ListingCommand();

  /// The command for [key] pressed on [folder] with the cursor on the row
  /// at [at] (a root-relative path, `null` on an empty folder), or `null`
  /// when the key means nothing here and should go on to the rest of the
  /// app.
  ///
  /// Up and Down move by a row, Home and End to either end; Enter opens
  /// the cursor's row when it is a folder; Backspace and Alt+Up open the
  /// folder above, as in a file manager. An arrow at either end still
  /// answers — with the row the cursor is already on — so it is not handed
  /// on to move the focus off the listing. Keys held with Ctrl, Cmd or
  /// Shift are left alone: they are not bound here, and a range selection
  /// would be the natural thing for Shift to grow into.
  static ListingCommand? forKey(
    LogicalKeyboardKey key, {
    required FiltersFolderListed folder,
    required String? at,
    required bool alt,
    required bool modified,
  }) {
    if (modified) return null;
    final entries = folder.entries;
    if ((key == LogicalKeyboardKey.backspace && !alt) ||
        (key == LogicalKeyboardKey.arrowUp && alt)) {
      return switch (parentOf(folder.path)) {
        final parent? => OpenListingFolder(parent),
        null => null,
      };
    }
    if (alt || entries.isEmpty) return null;
    final from = entries.indexWhere((entry) => entry.path == at);
    final last = entries.length - 1;
    final int? to;
    if (key == LogicalKeyboardKey.arrowDown) {
      to = from < 0 ? 0 : (from + 1).clamp(0, last);
    } else if (key == LogicalKeyboardKey.arrowUp) {
      to = from < 0 ? 0 : (from - 1).clamp(0, last);
    } else if (key == LogicalKeyboardKey.home) {
      to = 0;
    } else if (key == LogicalKeyboardKey.end) {
      to = last;
    } else {
      to = null;
    }
    if (to != null) return MoveListingCursor(entries[to].path);
    if (key == LogicalKeyboardKey.enter ||
        key == LogicalKeyboardKey.numpadEnter) {
      if (from < 0 || !entries[from].isFolder) return null;
      return OpenListingFolder(entries[from].path);
    }
    return null;
  }
}

/// Put the cursor on the row at [path].
final class MoveListingCursor extends ListingCommand {
  const MoveListingCursor(this.path);

  final String path;

  @override
  bool operator ==(Object other) =>
      other is MoveListingCursor && other.path == path;

  @override
  int get hashCode => Object.hash(MoveListingCursor, path);
}

/// Open the folder at [path] — a row, or the folder above.
final class OpenListingFolder extends ListingCommand {
  const OpenListingFolder(this.path);

  final String path;

  @override
  bool operator ==(Object other) =>
      other is OpenListingFolder && other.path == path;

  @override
  int get hashCode => Object.hash(OpenListingFolder, path);
}

/// The folder above the root-relative [path], or `null` for the root —
/// the page never lists above the folder being filtered.
String? parentOf(String path) {
  if (path.isEmpty) return null;
  final slash = path.lastIndexOf('/');
  return slash < 0 ? '' : path.substring(0, slash);
}

/// Where the cursor rests once [listed] is on screen, given it was on the
/// row at [at] in the folder at [cameFrom] (`null` when nothing was
/// listed before).
///
/// A re-listing of the same folder — a rule changed — keeps it on its
/// row. Going up, to the parent or further along the breadcrumb, lands it
/// on the folder the user came out of, so Backspace then Enter is a round
/// trip and a walk back up the tree does not lose the user's place.
/// Anything else starts at the first row. `null` only for an empty
/// folder.
String? cursorAfterListing(
  FiltersFolderListed listed, {
  required String? cameFrom,
  required String? at,
}) {
  final entries = listed.entries;
  if (entries.isEmpty) return null;
  bool shows(String? path) => entries.any((entry) => entry.path == path);
  if (shows(at)) return at;
  if (cameFrom != null) {
    final toward = _childToward(listed.path, cameFrom);
    if (shows(toward)) return toward;
  }
  return entries.first.path;
}

/// The child of [folder] on the way down to [descendant], or `null` when
/// [descendant] is not under [folder].
String? _childToward(String folder, String descendant) {
  final prefix = folder.isEmpty ? '' : '$folder/';
  if (descendant == folder || !descendant.startsWith(prefix)) return null;
  final rest = descendant.substring(prefix.length);
  return prefix + rest.split('/').first;
}

/// The scroll offset that brings row [index] of a list of [count]
/// equal-height rows wholly into view with the least movement, or `null`
/// when it already is.
///
/// [content] is the scroll view's whole extent (its `maxScrollExtent`
/// plus the [viewport]), of which [leading] and [trailing] are the list's
/// own padding; the rows share the rest equally, which the listing makes
/// exact by giving every row one prototype's height.
double? revealOffset({
  required int index,
  required int count,
  required double content,
  required double leading,
  required double trailing,
  required double viewport,
  required double pixels,
}) {
  final row = (content - leading - trailing) / count;
  // The first row brings the list's own top padding with it.
  final top = index == 0 ? 0.0 : leading + index * row;
  final bottom = leading + (index + 1) * row;
  if (top < pixels) return top;
  if (bottom > pixels + viewport) return bottom - viewport;
  return null;
}
