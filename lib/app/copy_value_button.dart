import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';

/// Puts one value on the clipboard, exactly as stored, and says so.
///
/// **For values meant to be carried somewhere else** — a device id pasted
/// into `dsync pair grant`, an address typed on the other device, a path
/// pasted into a shell. Every page's read-only text is already selectable
/// (see the selection rule below), but drag-selecting grouped hex or a long
/// path is a reach for exactly the right characters, and a value whose
/// point is to leave the app deserves one click that cannot pick up a stray
/// space or miss a group. The button copies [value] itself, not what is
/// drawn: where a label is elided or wrapped, the stored string is still
/// what lands on the clipboard.
///
/// **Confirmed with a snack bar**, the way the app confirms every other
/// completed action: the icon gives no feedback of its own, and a copy that
/// says nothing is a copy the user repeats to be sure. [what] names the
/// value once, for both the tooltip ("Copy device id") and the
/// confirmation ("Device id copied."), so the two cannot drift apart.
///
/// **The selection rule it sits beside.** Form and detail pages — This
/// device, Settings, Serve, Shared folders, a device's page, Pair, Pair
/// show, Run setup — wrap their whole body in one `SelectionArea` and opt
/// out what answers a click: `SelectionContainer.disabled` around tappable
/// rows, switches and text-labelled buttons, so a drag across the page
/// copies content, not control labels. Text fields stay in; a field is not
/// part of a page's selection anyway, wins its own drags, and the refusal
/// under it is an error line like any other.
///
/// Pages built around a listing whose rows answer clicks — the Run review,
/// Filters, Sync history, Devices, the saved runs, the file chooser — keep
/// the listing outside every `SelectionArea` and give each read-only block
/// around it (notices, headers, failure lines) its own. Opting such rows
/// out is not enough: `SelectionContainer.disabled` takes their text out of
/// the selection but not their pointers out of the region's gesture
/// recognisers, so a click held past the press timeout moves the focus into
/// the region — away from a listing that took it on pointer down — and on a
/// phone the region's long-press races a row's own.
class CopyValueButton extends StatelessWidget {
  const CopyValueButton({super.key, required this.value, required this.what});

  /// What goes on the clipboard, byte for byte.
  final String value;

  /// What [value] is, lower case, as a phrase that follows "Copy": "device
  /// id", "address", "folder path".
  final String what;

  @override
  Widget build(BuildContext context) {
    return IconButton(
      icon: const Icon(Icons.copy_outlined),
      tooltip: 'Copy $what',
      onPressed: () => copyValue(context, value: value, what: what),
    );
  }
}

/// [CopyValueButton]'s copy, for a copy offered somewhere other than its
/// own button — a row's menu (`RowCopy`) — so both put [value] on the
/// clipboard byte for byte and confirm it in the same words.
Future<void> copyValue(
  BuildContext context, {
  required String value,
  required String what,
}) async {
  final messenger = ScaffoldMessenger.of(context);
  await Clipboard.setData(ClipboardData(text: value));
  messenger.showSnackBar(
    SnackBar(
      content: Text(
        '${what.substring(0, 1).toUpperCase()}${what.substring(1)} copied.',
      ),
    ),
  );
}
