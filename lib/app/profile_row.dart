import 'core_link/models/profile_entry.dart';
import 'format_path.dart';
import 'profile_breakage.dart';

/// One saved profile as the head's home list displays it: every field is
/// the value a widget puts on screen, not the fact it would derive it from.
///
/// The branch here is brokenness — whether this profile can still be run —
/// and it is decided once, in [render], from the facts the core listed the
/// profile with: whether its device is still paired *now*, and the core's
/// folder check (SPEC §3) on its local root.
///
/// [breakage] is the whole of that decision: a broken profile *renders*
/// rather than disappearing (the run it names is still the run the user
/// configured), it is not a tap target while it cannot be run, and the case
/// says which remedy the row offers in place of that tap — re-picking the
/// local folder, or pairing with the peer again. The page reads [breakage]
/// and switches; it never re-derives what is wrong.
class ProfileRow {
  const ProfileRow({
    required this.name,
    required this.entryIds,
    required this.peerDeviceId,
    required this.peerName,
    required this.localRootPath,
    required this.remoteRootPath,
    required this.localRootLabel,
    required this.remoteRootLabel,
    required this.breakage,
    required this.lastRunUnfinished,
  });

  /// [profile] as the core listed it: its device's name *now* (`null`
  /// once revoked), the core's refusal of its local root (`null` while
  /// the folder is usable), and whether its run marker (SPEC §7.6) is
  /// still there.
  ///
  /// The row shows the profile's first entry, whose local root is what the
  /// folder remedy re-picks.
  factory ProfileRow.render(HeadProfile profile) {
    final first = profile.entries.first;
    final ProfileBreakage? broken;
    if (profile.peerName == null) {
      broken = const ProfileDeviceUnpaired();
    } else if (first.localRootRefusal != null) {
      broken = const ProfileLocalRootUnusable();
    } else {
      broken = null;
    }
    return ProfileRow(
      name: profile.name,
      entryIds: [for (final entry in profile.entries) entry.entryId],
      peerDeviceId: profile.peerDeviceId,
      peerName: profile.peerName,
      localRootPath: first.localRoot,
      remoteRootPath: first.remoteRoot,
      localRootLabel: PathLabel.of(first.localRoot),
      remoteRootLabel: PathLabel.of(first.remoteRoot),
      breakage: broken,
      lastRunUnfinished: broken == null && profile.lastRunUnfinished,
    );
  }

  /// What the user named the run: the profile's key in the core's store,
  /// what a tap hands the Run setup page and what a delete is addressed by.
  final String name;

  /// The ids the core derives from each entry's two sides, in entry
  /// order: what the profile's archive logs are filed under.
  final List<String> entryIds;

  /// The peer's grouped device id, kept as what the row shows in place of
  /// [peerName] when the device has been revoked — an id is all this host
  /// still knows the peer by then.
  final String peerDeviceId;

  /// The peer's name as the paired-device store has it *now*, or `null`
  /// when the profile's device has been revoked — a revoked device has no
  /// name on this host any more, only an id.
  final String? peerName;

  /// The first entry's side `a`, the absolute path the run syncs.
  final String localRootPath;

  /// The first entry's side `b`, unexpanded.
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

  /// Whether to warn that this profile's last run did not finish and offer
  /// to run it again (task 99f404). Never alongside a [breakage]: a profile
  /// that cannot be run has its remedy to show first, and running it again
  /// is not one of them until that is fixed.
  final bool lastRunUnfinished;
}
