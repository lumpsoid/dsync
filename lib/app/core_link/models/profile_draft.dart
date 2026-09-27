import 'entry_draft.dart';

/// The head's profile as entered: each of [entries] syncs a root on this
/// device with one on the paired device [peerDeviceId].
final class ProfileDraft {
  const ProfileDraft({
    required this.peerDeviceId,
    required this.entries,
    this.jobs,
    this.ignorePatterns = const [],
  });

  final String peerDeviceId;
  final List<EntryDraft> entries;
  final int? jobs;
  final List<String> ignorePatterns;
}
