/// One saved profile, by the shape the core found it in.
sealed class ProfileEntry {
  const ProfileEntry(this.name);

  final String name;
}

/// The head's shape: this device's folder with one on a paired device.
final class HeadProfile extends ProfileEntry {
  const HeadProfile({
    required String name,
    required this.profileId,
    required this.localRoot,
    required this.localRootExpanded,
    required this.localRootRefusal,
    required this.peerDeviceId,
    required this.peerName,
    required this.remoteRoot,
    required this.jobs,
    required this.ignorePatterns,
    required this.lastRunUnfinished,
  }) : super(name);

  final String profileId;
  final String localRoot;
  final String localRootExpanded;

  /// Why the local root cannot be a replica root now, if it cannot.
  final String? localRootRefusal;
  final String peerDeviceId;

  /// The device's name now; `null` when it is no longer paired.
  final String? peerName;
  final String remoteRoot;
  final int? jobs;
  final List<String> ignorePatterns;

  /// SPEC §7.6's run marker is present.
  final bool lastRunUnfinished;
}

/// Any other pair (a profile written for the CLI): runnable, not editable
/// here.
final class OtherProfile extends ProfileEntry {
  const OtherProfile({
    required String name,
    required this.profileId,
    required this.a,
    required this.b,
  }) : super(name);

  final String? profileId;
  final String a;
  final String b;
}

/// A profile file that would not load; [message] says why.
final class UnreadableProfile extends ProfileEntry {
  const UnreadableProfile({required String name, required this.message})
    : super(name);

  final String message;
}
