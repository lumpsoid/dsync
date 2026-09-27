import 'package:flutter/widgets.dart';

/// How the app shell has placed the Devices page: who draws its ways to
/// This device and Shared folders — the page's own app bar, or the shell
/// around it — and whether the list is the left pane of two, beside the
/// device it has selected.
///
/// A sum type rather than nullable callbacks so the page draws both or
/// neither — no layout puts one in the app bar and the other on the rail,
/// and a pair of nullables would let a caller build that. Likewise the
/// selected device only exists where there is a pane beside the list to
/// show it in, so it is a field of that case and not a nullable beside the
/// others. The page never works out which case applies; the shell decides
/// from the window, once.
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
/// their own, beside the page, and a tapped device opens over the list.
final class DevicesShellChrome extends DevicesChrome {
  const DevicesShellChrome();
}

/// The list is the left pane of two, with the selected device's page
/// beside it; the shell carries This device and Shared folders, as in
/// [DevicesShellChrome].
///
/// The list works like a desktop list here rather than a stack of links:
/// the selected row is marked, a click or Enter selects a row and keeps
/// keyboard focus on it, and Up and Down move the selection. Each move is
/// the page's `onOpenDevice`, so the shell stays the only owner of the
/// selection and this value only reports it back.
final class DevicesBesideDetailChrome extends DevicesChrome {
  const DevicesBesideDetailChrome({required this.selectedDeviceId});

  /// The device whose page is beside the list, or `null` while none is.
  final String? selectedDeviceId;
}
