import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// The keyboard half of a page's manual refresh: F5, Ctrl+R and, on a Mac
/// keyboard, Cmd+R run [onRefresh] anywhere on the page.
///
/// Pull-to-refresh is the only other way to refresh a list, and the desktop's
/// scroll behaviour does not drag with a mouse — nor should it, because no
/// one expects to drag a desktop list down. The key, with [RefreshButton]
/// for the mouse, is the desktop's way in.
///
/// Wraps [child] in an autofocused [Focus] so the key has somewhere to land
/// the moment the page's route is shown: without a focused node inside it a
/// page that has not been clicked yet hears no keys at all. Key events bubble
/// up from whatever inside the page holds focus, so a tabbed-to button does
/// not take the shortcut away.
///
/// Lives in `app/` beside the other cross-feature pieces because Profiles,
/// Devices and Sync history all refresh, and a shortcut bound three times is
/// three chances for the bindings to drift apart.
class RefreshShortcuts extends StatelessWidget {
  const RefreshShortcuts({
    super.key,
    required this.onRefresh,
    required this.child,
  });

  final VoidCallback onRefresh;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.f5): onRefresh,
        const SingleActivator(LogicalKeyboardKey.keyR, control: true):
            onRefresh,
        const SingleActivator(LogicalKeyboardKey.keyR, meta: true): onRefresh,
      },
      child: Focus(autofocus: true, child: child),
    );
  }
}

/// The pointer half of a page's manual refresh: an app-bar action that runs
/// [onRefresh], drawn on the desktop only.
///
/// **Gated on the platform, and here rather than in each page.** On a phone
/// pull-to-refresh is the platform's own idiom and the app bar is already
/// full, so the button would cost a slot to repeat what the thumb does; on
/// the desktop there is no pull, so the button is the only thing a mouse can
/// reach. The platform is read from the theme — the one Material itself
/// adapts on — so a test can pick it.
class RefreshButton extends StatelessWidget {
  const RefreshButton({super.key, required this.onRefresh});

  final VoidCallback onRefresh;

  @override
  Widget build(BuildContext context) {
    return switch (Theme.of(context).platform) {
      TargetPlatform.linux ||
      TargetPlatform.macOS ||
      TargetPlatform.windows => IconButton(
        icon: const Icon(Icons.refresh),
        tooltip: 'Refresh (F5)',
        onPressed: onRefresh,
      ),
      TargetPlatform.android ||
      TargetPlatform.iOS ||
      TargetPlatform.fuchsia => const SizedBox.shrink(),
    };
  }
}
