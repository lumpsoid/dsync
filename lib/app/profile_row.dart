import 'package:dsync/dsync_core/models/paired_device.dart';

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
/// [brokenReason] is the whole line to show instead of a tap target: a
/// broken profile *renders* rather than disappearing (the run it names is
/// still the run the user configured), and nothing about a broken row is
/// tappable — the page reads [brokenReason] and renders the row inert.
class ProfileRow {
  const ProfileRow({
    required this.id,
    required this.name,
    required this.peerDeviceId,
    required this.peerName,
    required this.localRootPath,
    required this.remoteRootPath,
    required this.brokenReason,
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
    final String? broken;
    if (device == null) {
      broken =
          'The device this profile syncs with is no longer paired. Pair '
          'again, then delete this profile and save it from a working run.';
    } else if (localRootRefusal != null) {
      broken =
          'The local folder is no longer accessible. Grant access to it '
          'again, or delete this profile and save it from a working run.';
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
      brokenReason: broken,
    );
  }

  /// The profile's own key, what a tap hands the Run setup page and what a
  /// delete is addressed by.
  final String id;

  /// What the user named the run.
  final String name;

  /// The peer's grouped device id, kept so the page's [onOpenProfile]-shaped
  /// handoff can carry an id without the entrypoint opening a store.
  final String peerDeviceId;

  /// The peer's name as the paired-device store has it *now*, or `null`
  /// when the profile's device has been revoked — a revoked device has no
  /// name on this host any more, only an id.
  final String? peerName;

  /// Side `a`, the absolute path the run syncs.
  final String localRootPath;

  /// Side `b`, unexpanded.
  final String remoteRootPath;

  /// Why this profile cannot be run any more, or `null` while it can.
  final String? brokenReason;
}
