import 'format_path.dart';
import 'paired_device_row.dart';

/// One folder this host serves, and every paired device's standing against
/// it — the paired-device list turned inside out.
///
/// The store has no such thing as a folder. `paired-devices.json` holds a
/// set of authorized roots *per device* (SPEC §4.4), so "which devices may
/// reach `~/Sync`" is a question only the whole list can answer, and
/// answering it per widget would mean every row walking every device. It is
/// answered once, here, in [renderAll], from the rows the head already has
/// on `AppState.devices` — no second read of the store, per the head's one
/// copy rule.
///
/// Every field is already rendered, per the view-state role in
/// `app_scope.dart`: the page draws these strings and toggles and decides
/// nothing.
///
/// **This is what this host serves outward, and only that.** A grant is
/// one-sided and told to nobody (SPEC §4.4): nothing here says, or could
/// say, what a peer serves back to this device. The devices named on a row
/// are the devices *allowed to ask* this host for that folder.
class SharedFolderRow {
  const SharedFolderRow({
    required this.rootPath,
    required this.label,
    required this.devices,
    required this.reachSummary,
    required this.note,
  });

  /// The stored path, byte for byte as it sits in every device's root set —
  /// what a grant or a withdrawal is addressed by, and what a `hello`
  /// handler compares a requested root against. Never elided.
  final String rootPath;

  /// [rootPath] as a one-line label, middle-elided by [elidePath]: folders
  /// on one host share a long prefix, so the end is what tells two rows
  /// apart.
  final String label;

  /// Every paired device, each carrying whether this folder is granted to
  /// it. The whole list rather than only the devices that may reach it,
  /// because the page grants by toggling a device *on*: a device that is
  /// not on the folder yet is exactly the row a user came here to tap.
  final List<SharedFolderDevice> devices;

  /// Who may reach this folder, as a sentence — the line under the path.
  final String reachSummary;

  /// The one remark a row can carry, or `null`. A folder granted to a
  /// single device is one toggle away from being granted to nobody, and a
  /// root granted to nobody is stored nowhere: it disappears from this page
  /// and from the store together, because the store only ever holds roots
  /// per device. That is not a loss of data — no file is touched — but it
  /// is a surprise if nothing says so first.
  final String? note;

  /// How many devices may reach this folder.
  int get shareCount => devices.where((device) => device.isShared).length;

  /// Inverts [rows] — the head's paired devices — into one row per folder
  /// this host serves, sorted by path so the order on screen is the set's
  /// and not any one device's.
  ///
  /// A device with no grants contributes no folder and still appears as an
  /// off toggle on every row, which is what makes this page a way of
  /// granting rather than only a way of reviewing.
  static List<SharedFolderRow> renderAll(List<PairedDeviceRow> rows) {
    final roots = <String>{
      for (final row in rows) ...row.agreedRootLabels.keys,
    }.toList()..sort();
    final folders = <SharedFolderRow>[];
    for (final root in roots) {
      final names = [
        for (final row in rows)
          if (row.agreedRootLabels.containsKey(root)) row.name,
      ];
      folders.add(
        SharedFolderRow(
          rootPath: root,
          label: elidePath(root),
          devices: devicesOf(rows, rootPath: root),
          reachSummary: _summarize(names),
          note: _noteFor(names),
        ),
      );
    }
    return folders;
  }

  /// Every paired device against one folder. [rootPath] is `null` for a
  /// folder that is not shared with anyone yet — the add flow, where the
  /// path is still being chosen and every device starts off.
  static List<SharedFolderDevice> devicesOf(
    List<PairedDeviceRow> rows, {
    required String? rootPath,
  }) {
    return [
      for (final row in rows)
        SharedFolderDevice(
          deviceId: row.deviceId,
          name: row.name,
          isShared:
              rootPath != null && row.agreedRootLabels.containsKey(rootPath),
        ),
    ];
  }

  /// Who may reach a folder, in the user's words. Names rather than a
  /// count: the count is what the row would show if the devices were the
  /// detail, and here they are the point.
  static String _summarize(List<String> names) {
    if (names.isEmpty) return 'No device may reach this folder.';
    if (names.length == 1) return 'Only ${names.first} may reach this folder.';
    final last = names.last;
    final rest = names.sublist(0, names.length - 1).join(', ');
    return '$rest and $last may reach this folder.';
  }

  /// The warning a one-device folder carries, so the disappearance below is
  /// not a surprise.
  static String? _noteFor(List<String> names) {
    if (names.length != 1) return null;
    return 'Turning ${names.first} off leaves this folder shared with '
        'nobody, and it stops being listed here.';
  }
}

/// One paired device's standing against one folder: this host's own name
/// for it, the id a grant is addressed by, and whether the folder is
/// granted to it today.
///
/// [isShared] is the toggle's position, already decided — the page reads it
/// and never asks a device what it holds.
class SharedFolderDevice {
  const SharedFolderDevice({
    required this.deviceId,
    required this.name,
    required this.isShared,
  });

  /// SPEC §4.4's grouped hex — the handoff to `grantRoot`/`revokeRoot`.
  final String deviceId;

  /// What this host calls the device. The peer's own name for itself is
  /// not this, and is not known here.
  final String name;

  /// Whether this device may reach the folder this row is about.
  final bool isShared;
}
