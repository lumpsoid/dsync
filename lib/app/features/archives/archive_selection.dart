import 'package:flutter/foundation.dart';

/// The rows ticked on the Sync history page, by log path, and where the
/// next range starts: the desktop list's selection model, as a value.
///
/// **Ids, not positions.** Every operation that needs the list's order is
/// handed it; nothing here remembers an index. A refresh that reorders or
/// shortens the list therefore cannot move a tick onto a row the user
/// never picked — the path either is still listed or is gone ([retain]).
///
/// **The anchor is where Shift ranges from.** Each tick or untick moves it
/// to the row just clicked, and a range replaces the previous range from
/// the same anchor rather than adding to it, so Shift+Down then Shift+Up
/// shrinks the range back the way it grew. What was ticked before the
/// anchor was set — the [_base] — is kept under every range, so Ctrl-click
/// three rows and Shift-click a fourth span loses none of the three. That
/// is the Finder's and Explorer's Ctrl+Shift behaviour; a plain Shift-click
/// wiping the earlier ticks would make a delete list punish the user for
/// picking carefully.
///
/// **Empty is one value.** [none] has no ticks, no anchor and no base: a
/// last untick, a clear, or a refresh that leaves nothing ticked all land
/// on it, so "not selecting" cannot carry a stale anchor into the next
/// Shift-click.
@immutable
final class ArchiveSelection {
  const ArchiveSelection._(this.ids, this.anchor, this._base);

  /// Nothing ticked — the page is not selecting.
  static const none = ArchiveSelection._({}, null, {});

  /// The ticked log paths.
  final Set<String> ids;

  /// The row the next range starts from, or `null` when none is set — no
  /// row has been clicked since the selection began, or the anchor's row
  /// was deleted from under it.
  final String? anchor;

  /// What stays ticked under a range from [anchor]: the selection as it
  /// was when the anchor was last set.
  final Set<String> _base;

  bool get isEmpty => ids.isEmpty;

  bool contains(String id) => ids.contains(id);

  /// Ticks [id] if it was not, unticks it if it was — Ctrl-click, Space,
  /// and any click once selecting — and makes it the anchor.
  ArchiveSelection toggle(String id) {
    final next = {...ids};
    if (!next.remove(id)) next.add(id);
    return _of(next, anchor: id, base: next);
  }

  /// Ticks every row between the anchor and [to] in [order], both ends
  /// included, over what was ticked when the anchor was set — Shift-click
  /// and Shift+Up/Down.
  ///
  /// With no anchor the range starts at [from]: the row the keyboard focus
  /// is on, which is where a desktop list ranges from before anything has
  /// been clicked. With neither, it is [to] alone, which becomes the
  /// anchor. An end [order] does not hold ranges over [to] alone as well —
  /// a row a refresh just took away has no place to range from.
  ArchiveSelection selectRange(
    List<String> order, {
    required String? from,
    required String to,
  }) {
    final start = anchor ?? from ?? to;
    final base = anchor == null ? ids : _base;
    final i = order.indexOf(start);
    final j = order.indexOf(to);
    final range = i < 0 || j < 0
        ? [to]
        : order.sublist(i < j ? i : j, (i < j ? j : i) + 1);
    return _of({...base, ...range}, anchor: i < 0 ? to : start, base: base);
  }

  /// Ticks every row in [order] — Ctrl+A. The anchor stays where it was,
  /// so a Shift-click after it ranges from the row last clicked.
  ArchiveSelection selectAll(List<String> order) {
    final all = order.toSet();
    return _of(all, anchor: anchor, base: all);
  }

  /// Keeps only what [listed] still holds — after a refresh or a delete.
  /// A ticked path that is gone is dropped, not kept waiting for a row to
  /// come back: a tick the user cannot see is one a later delete would
  /// act on without them knowing. An anchor that is gone is dropped too.
  ArchiveSelection retain(Set<String> listed) => _of(
    ids.intersection(listed),
    anchor: listed.contains(anchor) ? anchor : null,
    base: _base.intersection(listed),
  );

  /// [ids] as the next value, or [none] when nothing is left ticked.
  static ArchiveSelection _of(
    Set<String> ids, {
    required String? anchor,
    required Set<String> base,
  }) => ids.isEmpty
      ? none
      : ArchiveSelection._(
          Set.unmodifiable(ids),
          anchor,
          Set.unmodifiable(base),
        );
}
