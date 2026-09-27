import 'entry_view.dart';
import 'other_entry.dart';

/// One saved profile, by the shape the core found it in.
sealed class ProfileEntry {
  const ProfileEntry(this.name);

  final String name;
}

/// The head's shape: every entry pairs a root on this device with one on
/// the same paired device.
final class HeadProfile extends ProfileEntry {
  const HeadProfile({
    required String name,
    required this.peerDeviceId,
    required this.peerName,
    required this.jobs,
    required this.ignorePatterns,
    required this.lastRunUnfinished,
    required this.entries,
  }) : super(name);

  final String peerDeviceId;

  /// The device's name now; `null` when it is no longer paired.
  final String? peerName;
  final int? jobs;
  final List<String> ignorePatterns;

  /// SPEC §7.6's run marker is present for any of the entries.
  final bool lastRunUnfinished;

  /// Never empty: the core refuses a profile without entries.
  final List<EntryView> entries;
}

/// Any other profile (one written for the CLI): runnable, not editable
/// here.
final class OtherProfile extends ProfileEntry {
  const OtherProfile({required String name, required this.entries})
    : super(name);

  final List<OtherEntry> entries;
}

/// A profile file that would not load; [message] says why.
final class UnreadableProfile extends ProfileEntry {
  const UnreadableProfile({required String name, required this.message})
    : super(name);

  final String message;
}
