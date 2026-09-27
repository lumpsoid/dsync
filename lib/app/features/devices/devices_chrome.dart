import 'package:flutter/widgets.dart';

/// Who draws the Devices page's ways to This device and Shared folders: the
/// page's own app bar, or the app shell around it.
///
/// A sum type rather than nullable callbacks so the page draws both or
/// neither — no layout puts one in the app bar and the other on the rail,
/// and a pair of nullables would let a caller build that. The page never
/// works out which case applies; the shell decides from the window, once.
///
/// Pairing is not in here: it acts on this list whatever the layout, so it
/// stays in the page's app bar and `DevicesPage.onOpenPair` stays required.
sealed class DevicesChrome {
  const DevicesChrome();
}

/// The page is the whole window: its app bar leads to This device and
/// Shared folders, which a compact window pushes over this list.
final class DevicesOwnChrome extends DevicesChrome {
  const DevicesOwnChrome({
    required this.onOpenThisDevice,
    required this.onOpenSharedFolders,
  });

  /// Opens the This device page, where this installation's own identity is
  /// shown and its certificate renewed.
  final VoidCallback onOpenThisDevice;

  /// Opens the Shared folders page: this list inverted, one row per folder
  /// this host serves and the devices allowed to ask for it. Reached from
  /// here because it answers the question the list next to it raises — the
  /// rows say which devices are paired, that page says what each of them
  /// may actually reach.
  final VoidCallback onOpenSharedFolders;
}

/// The shell carries This device and Shared folders as destinations of
/// their own, beside the page.
final class DevicesShellChrome extends DevicesChrome {
  const DevicesShellChrome();
}
