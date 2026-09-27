import 'package:flutter/widgets.dart';

/// Whether the keyboard focus is inside the widget [key] names — the widget
/// itself or anything under it, so a keyed `TextField` or button counts
/// when the `Focus` it builds holds the focus.
///
/// Asked of the focus manager rather than of the widget, because what the
/// keyboard tests assert is where the next key press lands.
bool focusIsWithin(Key key) {
  final focused = FocusManager.instance.primaryFocus?.context;
  if (focused == null) return false;
  if (focused.widget.key == key) return true;
  var found = false;
  focused.visitAncestorElements((element) {
    found = element.widget.key == key;
    return !found;
  });
  return found;
}
