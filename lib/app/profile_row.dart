import 'package:dsync/dsync_core/models/paired_device.dart';

import 'format_path.dart';
import 'profile_breakage.dart';
import 'sync_profile.dart';

/// One saved profile as the head's home list displays it: every field is
/// the value a widget puts on screen, not the fact it would derive it from.
///
/// Deliberately not a `SyncProfile`, for the same reason `PairedDeviceRow`
/// is not a `PairedDevice`: a widget holding the domain object is a widget
/// that will eventually branch on it. The branch here is brokenness —
/// whether this profile can still be run — and it is decided once, in
/// [render], from facts the controller has already fetched: a fresh read of
/// the paired-device store ([PairedDeviceStore]'s freshness rule — a device
/// revoked since the last refresh is unpaired *now*) and the same
/// filesystem probe Run setup runs on a folder it is offered.
///
/// [breakage] is the whole of that decision: a broken profile *renders*
/// rather than disappearing (the run it names is still the run the user
/// configured), it is not a tap target while it cannot be run, and the case
/// says which remedy the row offers in place of that tap — re-picking the
/// local folder, or pairing with the peer again. The page reads [breakage]
/// and switches; it never re-derives what is wrong.
class ProfileRow {
  const ProfileRow({
    required this.id,
    required this.name,
    required this.peerDeviceId,
    required this.peerName,
    required this.localRootPath,
    required this.remoteRootPath,
    required this.localRootLabel,
    required this.remoteRootLabel,
    required this.breakage,
  });

  /// [profile] against the facts fetched for it. [device] is the paired
  /// device [profile.peerDeviceId] resolves to *now*, `null` when it has
  /// been revoked; [localRootRefusal] is [folderAccessRefusal]'s verdict on
  /// the local root, `null` when the folder is still provably usable.
  factory ProfileRow.render(
    SyncProfile profile, {
    required PairedDevice? device,
    required String? localRootRefusal,
  }) {
    final ProfileBreakage? broken;
    if (device == null) {
      broken = const ProfileDeviceUnpaired();
    } else if (localRootRefusal != null) {
      broken = const ProfileLocalRootUnusable();
    } else {
      broken = null;
    }
    return ProfileRow(
      id: profile.id,
      name: profile.name,
      peerDeviceId: profile.peerDeviceId,
      peerName: device?.name,
      localRootPath: profile.localRootPath,
      remoteRootPath: profile.remoteRootPath,
      localRootLabel: PathLabel.of(profile.localRootPath),
      remoteRootLabel: PathLabel.of(profile.remoteRootPath),
      breakage: broken,
    );
  }

  /// The profile's own key, what a tap hands the Run setup page and what a
  /// delete is addressed by.
  final String id;

  /// What the user named the run.
  final String name;

  /// The peer's grouped device id, kept as what the row shows in place of
  /// [peerName] when the device has been revoked — an id is all this host
  /// still knows the peer by then.
  final String peerDeviceId;

  /// The peer's name as the paired-device store has it *now*, or `null`
  /// when the profile's device has been revoked — a revoked device has no
  /// name on this host any more, only an id.
  final String? peerName;

  /// Side `a`, the absolute path the run syncs.
  final String localRootPath;

  /// Side `b`, unexpanded.
  final String remoteRootPath;

  /// [localRootPath] as the row prints it: split by [PathLabel] into the
  /// leaf that tells two runs apart and the prefix every folder on the
  /// device shares, so the row can draw the one loud and the other quiet.
  final PathLabel localRootLabel;

  /// [remoteRootLabel] is [remoteRootPath] under the same rule. Rendered
  /// here rather than in the tile for the reason the rest of this class
  /// exists: the page draws values, it does not derive them.
  final PathLabel remoteRootLabel;

  /// Why this profile cannot be run any more and what fixes it, or `null`
  /// while it can be run.
  final ProfileBreakage? breakage;
}
