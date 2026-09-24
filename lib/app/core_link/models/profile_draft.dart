/// The head's profile as entered: this device's [localRoot] synced with
/// [remoteRoot] on the paired device [peerDeviceId].
final class ProfileDraft {
  const ProfileDraft({
    required this.localRoot,
    required this.peerDeviceId,
    required this.remoteRoot,
    this.jobs,
    this.ignorePatterns = const [],
  });

  final String localRoot;
  final String peerDeviceId;
  final String remoteRoot;
  final int? jobs;
  final List<String> ignorePatterns;
}
