/// Where the core keeps what it stores, as `init` resolved it: the state
/// directory (identity, pairings, archives - and the head's own
/// `settings.json` beside them, so the head never writes where an older
/// build kept its state) and the directory of saved profiles.
final class CoreDirs {
  const CoreDirs({required this.stateDir, required this.profilesDir});

  final String stateDir;
  final String profilesDir;
}
