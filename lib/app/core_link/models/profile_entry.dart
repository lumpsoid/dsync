import 'entry_view.dart';
import 'last_run.dart';
import 'other_entry.dart';

/// One saved profile, by the shape the core found it in — or a run no
/// saved profile claims.
sealed class ProfileEntry {
  const ProfileEntry();
}

/// The head's shape: every entry pairs a root on this device with one on
/// the same paired device.
final class HeadProfile extends ProfileEntry {
  const HeadProfile({
    required this.name,
    required this.peerDeviceId,
    required this.peerName,
    required this.jobs,
    required this.ignorePatterns,
    required this.lastRun,
    required this.entries,
  });

  final String name;
  final String peerDeviceId;

  /// The device's name now; `null` when it is no longer paired.
  final String? peerName;
  final int? jobs;
  final List<String> ignorePatterns;

  final LastRun lastRun;

  /// Never empty: the core refuses a profile without entries.
  final List<EntryView> entries;
}

/// Any other profile (one written for the CLI): runnable, not editable
/// here.
final class OtherProfile extends ProfileEntry {
  const OtherProfile({required this.name, required this.entries});

  final String name;
  final List<OtherEntry> entries;
}

/// A profile file that would not load; [message] says why.
final class UnreadableProfile extends ProfileEntry {
  const UnreadableProfile({required this.name, required this.message});

  final String name;
  final String message;
}

/// A run marker (SPEC §7.6) of an entry no saved profile has: a run
/// started without saving it did not finish (task 75af93).
final class UnsavedRun extends ProfileEntry {
  const UnsavedRun({
    required this.entryId,
    required this.pair,
    required this.lastRun,
  });

  final String entryId;

  /// The two replicas as the run named them; `null` when the marker does
  /// not say.
  final OtherEntry? pair;

  /// Never [LastRun.settled]: there is a marker.
  final LastRun lastRun;
}
