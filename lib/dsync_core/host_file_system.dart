import 'package:path/path.dart' as p;

/// How a replica's *own* filesystem behaves on the host holding it (SPEC §3):
/// how its paths are spelled, and whether `chmod` exists to shell out to
/// (SPEC §7.4).
///
/// One value for both, because they are one fact. `pathStyle ==
/// p.Style.windows` and "no `chmod`" are true together on exactly the same
/// platform and false together everywhere else, so a head that resolved them
/// separately could hand a `Scanner` Windows paths and a `LocalAgent` a
/// `chmod` that is not there — a combination this enum cannot express
/// (CLAUDE.md "Make invalid states unrepresentable").
///
/// It lives in `core`, beside the state- and config-directory rules, because
/// both heads need it: the CLI resolves it from `Platform.operatingSystem`
/// at its edge (`lib/cli/host_platform.dart`) and the Flutter head from the
/// same read in `AppPaths.forHost` (`lib/app/app_paths.dart`). Neither reads
/// the host again downstream — the value is threaded down, the same
/// convention the environment map and the state directory already follow.
///
/// The two members are getters rather than fields: an enum's fields must be
/// `const`, and `p.Style`'s constants are `static final` (`package:path`
/// resolves `Style.platform` at load time), which is the same reason
/// `Scanner` and `LocalAgent` apply their POSIX fallback in a constructor
/// body instead of a default value.
enum HostFileSystem {
  /// Linux, macOS, Android and iOS: `/`-separated paths, `chmod` available.
  posix,

  /// Windows: `\`-separated paths (SPEC §3's read-side conversion), and no
  /// `chmod` and no POSIX permission-bit model to translate one into
  /// (SPEC §7.4).
  windows;

  /// The `package:path` style a replica on this host is read with — what a
  /// `Scanner` splits a child's own name out of `FileSystemEntity.path`
  /// with before rejoining it into the `/`-normalized, root-relative form
  /// the wire (SPEC §4.2) and the archive (SPEC §8.1) both assume.
  p.Style get pathStyle =>
      this == HostFileSystem.windows ? p.Style.windows : p.Style.posix;

  /// Whether `LocalAgent._applyMode` should skip the `chmod` spawn outright
  /// (SPEC §7.4) rather than discover its absence empirically, at the cost
  /// of one guaranteed-to-fail `Process.run` per differing-mode file.
  bool get isWindowsReplica => this == HostFileSystem.windows;
}
