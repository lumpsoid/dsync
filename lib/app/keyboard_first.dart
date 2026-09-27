import 'package:flutter/material.dart';

/// Whether this host's user types on a hardware keyboard — the desktop — so
/// a long form may put the cursor in its first field the moment it opens.
///
/// **Only long forms ask.** A dialog whose whole point is typing (a rename,
/// an address, a pattern) focuses its field everywhere: the soft keyboard
/// rising with it is what the user came for. A form like Run setup is
/// different on a phone — its first thing to do is pick a folder, not
/// type, and a soft keyboard raised on arrival would cover half the form to
/// offer a field the user has not reached yet. On a desktop focusing it
/// costs nothing but a caret, and saves the click.
///
/// Decided here rather than in each page, from the theme's platform — the
/// one Material itself adapts on (`RefreshButton` reads it the same way) —
/// so a widget test picks it.
bool keyboardFirst(BuildContext context) =>
    switch (Theme.of(context).platform) {
      TargetPlatform.linux ||
      TargetPlatform.macOS ||
      TargetPlatform.windows => true,
      TargetPlatform.android ||
      TargetPlatform.iOS ||
      TargetPlatform.fuchsia => false,
    };
