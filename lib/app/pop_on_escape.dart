import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Esc backs out of a pushed page the way its app-bar arrow does:
/// `Navigator.maybePop`, so a page that guards its way out with a
/// `PopScope` is asked exactly as it is for the arrow and the system back.
///
/// **For the pages pushed over the whole window.** The shell binds Esc for
/// the pages in its pane (`_AppShellState` in `dsync_app.dart`), but Pair,
/// Pair show and Run setup — and the pages they push in turn — sit on the
/// root navigator, outside it. The app's own Esc binding does not reach
/// them either: it resolves to the nearest route's dismiss action, which a
/// page route declines. Without this, Esc closes every dialog and backs out
/// of every pane page, and does nothing at all on the pages a user is most
/// likely to have opened by mistake.
///
/// **Out of a text field first, then out of the page.** Esc in a focused
/// field only leaves the field; the next one leaves the page. A page that
/// focuses its first field on arrival would otherwise swallow Esc until the
/// user found something else to click, and popping straight out of a field
/// would throw away what was just typed on a key that, in a field, usually
/// means "stop editing".
///
/// **Takes focus itself, as a scope.** Keys reach only what is under the
/// focused node, and a page that has not been clicked yet has none — so
/// the wrapper is an autofocused [FocusScope] rather than the plain
/// autofocused `Focus` `RefreshShortcuts` uses. A scope's own focus does not
/// count as a focused child of it, so a field inside that asks for
/// autofocus still gets it; a plain `Focus` would have taken the page's one
/// autofocus and left the field's request discarded.
///
/// Lives in `app/` beside the other cross-feature pieces because six
/// pages in four features bind it, and one binding is one rule about what
/// Esc means.
class PopOnEscape extends StatelessWidget {
  const PopOnEscape({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Shortcuts(
      shortcuts: const {
        SingleActivator(LogicalKeyboardKey.escape): _EscapeIntent(),
      },
      child: Actions(
        actions: {
          _EscapeIntent: CallbackAction<_EscapeIntent>(
            onInvoke: (_) => _escape(context),
          ),
        },
        child: FocusScope(autofocus: true, child: child),
      ),
    );
  }

  static void _escape(BuildContext context) {
    final focused = FocusManager.instance.primaryFocus;
    final editing = focused?.context
        ?.findAncestorStateOfType<EditableTextState>();
    if (focused != null && editing != null) {
      focused.unfocus();
      return;
    }
    Navigator.maybePop(context);
  }
}

class _EscapeIntent extends Intent {
  const _EscapeIntent();
}
