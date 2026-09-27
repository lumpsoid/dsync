import 'package:flutter/material.dart';

/// The question before a write that cannot be taken back by pressing a
/// button — a delete, a revoke, a folder withdrawn — with the keyboard
/// defaults such a question needs.
///
/// **Focus starts on the safe choice.** [cancelLabel] is autofocused, so
/// Enter on a dialog that has just appeared answers "keep it": a dialog
/// reached by a key press is one Enter away from whatever the next key
/// press is, and a destructive default turns a double-tap of Enter into a
/// delete. Reaching the destructive button is a Tab or a click — one
/// deliberate step. Esc dismisses, as every Material dialog does, and pops
/// nothing, which every caller reads as "keep it".
///
/// **The destructive button is drawn in the error colour.** Filled, because
/// it is still the action the dialog is about; red, because it is the one
/// that loses something. That colour is what the eye checks before
/// clicking, not the label.
///
/// Autofocusing a button raises no soft keyboard, so the same defaults hold
/// on a phone: there the focus is invisible, and the tap is the answer.
///
/// Pops `true` for [confirmLabel], `false` for [cancelLabel], nothing when
/// dismissed. Lives in `app/` because every feature that deletes something
/// asks this way, and one widget is one set of defaults that cannot drift
/// between them.
class DestructiveConfirmDialog extends StatelessWidget {
  const DestructiveConfirmDialog({
    super.key,
    required this.title,
    required this.message,
    required this.cancelLabel,
    required this.confirmLabel,
    required this.cancelKey,
    required this.confirmKey,
  });

  final String title;

  /// What is lost and what is not, in the user's words.
  final String message;

  /// The safe answer, which has the focus: "Cancel", or the thing kept.
  final String cancelLabel;

  /// The destructive answer, named for what it does.
  final String confirmLabel;

  final Key cancelKey;
  final Key confirmKey;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return AlertDialog(
      title: Text(title),
      content: Text(message),
      actions: [
        TextButton(
          key: cancelKey,
          autofocus: true,
          onPressed: () => Navigator.of(context).pop(false),
          child: Text(cancelLabel),
        ),
        FilledButton(
          key: confirmKey,
          style: FilledButton.styleFrom(
            backgroundColor: scheme.error,
            foregroundColor: scheme.onError,
          ),
          onPressed: () => Navigator.of(context).pop(true),
          child: Text(confirmLabel),
        ),
      ],
    );
  }
}
