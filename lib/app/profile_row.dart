import 'core_link/models/entry_view.dart';
import 'core_link/models/profile_entry.dart';
import 'core_link/models/root_kind.dart';
import 'profile_breakage.dart';

/// One saved profile as the head's home list displays it: every field is
/// the value a widget puts on screen, not the fact it would derive it from.
///
/// The branch here is brokenness — whether this profile can still be run —
/// and it is decided once, in [render], from the facts the core listed the
/// profile with: whether its device is still paired *now*, and the core's
/// folder check (SPEC §3) on each entry's local root.
///
/// [breakage] is the whole of that decision: a broken profile *renders*
/// rather than disappearing (the run it names is still the run the user
/// configured), it is not a tap target while it cannot be run, and the case
/// says which remedy the row offers in place of that tap — re-picking an
/// entry's local folder, or pairing with the peer again. The page reads
/// [breakage] and switches; it never re-derives what is wrong.
class ProfileRow {
  const ProfileRow({
    required this.name,
    required this.peerDeviceId,
    required this.peerName,
    required this.entries,
    required this.breakage,
    required this.lastRunUnfinished,
  });

  /// [profile] as the core listed it: its device's name *now* (`null`
  /// once revoked), each entry's own folder refusal (`null` while it is
  /// usable), and whether its run marker (SPEC §7.6) is still there.
  factory ProfileRow.render(HeadProfile profile) {
    final entries = [
      for (final entry in profile.entries) ProfileEntryRow.render(entry),
    ];
    final ProfileBreakage? broken;
    if (profile.peerName == null) {
      broken = const ProfileDeviceUnpaired();
    } else {
      final brokenIndex = entries.indexWhere((entry) => entry.broken);
      broken = brokenIndex == -1 ? null : ProfileLocalRootUnusable(brokenIndex);
    }
    return ProfileRow(
      name: profile.name,
      peerDeviceId: profile.peerDeviceId,
      peerName: profile.peerName,
      entries: entries,
      breakage: broken,
      lastRunUnfinished: broken == null && profile.lastRunUnfinished,
    );
  }

  /// What the user named the run: the profile's key in the core's store,
  /// what a tap hands the Run setup page and what a delete is addressed by.
  final String name;

  /// The peer's grouped device id, kept as what the row shows in place of
  /// [peerName] when the device has been revoked — an id is all this host
  /// still knows the peer by then.
  final String peerDeviceId;

  /// The peer's name as the paired-device store has it *now*, or `null`
  /// when the profile's device has been revoked — a revoked device has no
  /// name on this host any more, only an id.
  final String? peerName;

  /// Every entry of the profile, in order, each already rendered.
  final List<ProfileEntryRow> entries;

  /// Why this profile cannot be run any more and what fixes it, or `null`
  /// while it can be run.
  final ProfileBreakage? breakage;

  /// Whether to warn that this profile's last run did not finish and offer
  /// to run it again (task 99f404). Never alongside a [breakage]: a profile
  /// that cannot be run has its remedy to show first, and running it again
  /// is not one of them until that is fixed.
  final bool lastRunUnfinished;

  /// The ids the core derives from each entry's two sides, in entry order:
  /// what the profile's archive logs are filed under.
  List<String> get entryIds => [for (final entry in entries) entry.entryId];

  /// The first entry's side `a`, the absolute path the run syncs — kept for
  /// callers that still think in terms of one pair (the archives page joins
  /// by id instead, per [entryIds]).
  String get localRootPath => entries.first.localRootPath;

  /// The first entry's side `b`, unexpanded.
  String get remoteRootPath => entries.first.remoteRootPath;
}

/// One entry of a [ProfileRow], already rendered: both its sides, and
/// whether its local root fails the core's folder check.
class ProfileEntryRow {
  const ProfileEntryRow({
    required this.entryId,
    required this.kind,
    required this.localRootPath,
    required this.remoteRootPath,
    required this.localRootRefusal,
  });

  factory ProfileEntryRow.render(EntryView entry) => ProfileEntryRow(
    entryId: entry.entryId,
    kind: entry.kind,
    localRootPath: entry.localRoot,
    remoteRootPath: entry.remoteRoot,
    localRootRefusal: entry.localRootRefusal,
  );

  final String entryId;
  final RootKind kind;
  final String localRootPath;
  final String remoteRootPath;

  /// Why this entry's local root cannot be a replica root now, or `null`
  /// while it can.
  final String? localRootRefusal;

  bool get broken => localRootRefusal != null;
}
