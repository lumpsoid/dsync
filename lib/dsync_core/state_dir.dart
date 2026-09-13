/// The directory dsync keeps per-replica state in (SPEC §8.3) — one archive
/// log and one lock file per profile and side.
///
/// `$XDG_STATE_HOME/dsync`, or `~/.local/state/dsync` when that is unset.
/// With neither variable set there is no sane answer, so this says so instead
/// of interpolating a null into a path and writing to a directory literally
/// named `null`.
///
/// Pure function of [environment] — it reads nothing implicitly — so callers
/// stay testable without touching the real process environment.
String resolveStateDir(Map<String, String> environment) {
  final stateHome = environment['XDG_STATE_HOME'];
  if (stateHome != null && stateHome.isNotEmpty) return '$stateHome/dsync';

  final home = environment['HOME'];
  if (home == null || home.isEmpty) {
    throw StateError(
      'Cannot locate the dsync state directory: neither XDG_STATE_HOME nor '
      'HOME is set',
    );
  }
  return '$home/.local/state/dsync';
}
