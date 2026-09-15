/// How the `ssh` transport reaches one remote replica (SPEC §4.2): the
/// options handed to the `ssh` executable, and the command that starts the
/// agent on the far side.
///
/// One object rather than two values threaded side by side from a profile
/// (`Profile.sshA`/`sshB`) down to `sshArgsFor`: an identity file that
/// belongs to one replica paired with a remote command that belongs to the
/// other is a mistake nothing downstream could notice, which is exactly the
/// cluster CLAUDE.md says to name.
///
/// Per replica, not per run — SPEC §4.1 allows a pair of two remotes, and
/// two hosts need not agree on where `dsync` lives or which key opens them.
///
/// Deliberately *not* part of a replica's identity: `EffectiveOptions`
/// canonicalizes and hashes the two locations alone. How a tree is reached
/// says nothing about which tree it is, and an ad-hoc profile id that
/// changed because a run added `-v` would hand that run a fresh, empty
/// archive and silently re-mirror everything (SPEC §5.2, §8.1).
///
/// A plain value object with no validation of its own: the messages that
/// matter for a bad value name the flag or the profile key it was entered
/// as, so the checks live where those names are known — `CliOptions` and
/// `loadProfile`.
class SshAccess {
  /// What starts the agent on the far side when nothing names it: the bare
  /// word, resolved on the remote *non-interactive* PATH (SPEC §4.2), which
  /// is where a real setup fails first.
  static const defaultCommand = 'dsync';

  /// Options for the `ssh` executable itself — `-p`, `-i`, `-o …` — placed
  /// before the destination, where ssh expects its own options rather than
  /// the remote command's.
  ///
  /// Empty by default, and expected to stay empty on most machines:
  /// `~/.ssh/config` already answers port, identity, user and proxy command
  /// per destination, and answering them twice is how the two disagree.
  final List<String> options;

  /// The command that starts the agent on the far side, placed where the
  /// bare `dsync` goes.
  ///
  /// One string rather than an argv, because ssh joins its command arguments
  /// back into a single string for the remote shell to parse anyway. So
  /// `XDG_STATE_HOME=/tmp/x /opt/bin/dsync` works as written, and a path with
  /// a space in it carries its own quoting — the same bargain `rsync`'s
  /// `--rsync-path` makes.
  final String command;

  const SshAccess({this.options = const [], this.command = defaultCommand});

  /// This access with one run's command-line values folded in (SPEC §12:
  /// "Command-line flags override profile options").
  ///
  /// [command] overrides, as SPEC §12 says. [options] is additive instead,
  /// like `--ignore` (SPEC §9) and for the same reason: a profile's `-i` is
  /// what makes the connection work at all, and a `--ssh-option=-v` typed
  /// once to see why a run failed must not silently drop it. Flag options are
  /// appended, and where the same option is given twice ssh's own precedence
  /// decides — this does not restate a rule that belongs to ssh.
  SshAccess withFlags({List<String> options = const [], String? command}) =>
      SshAccess(
        options: [...this.options, ...options],
        command: command ?? this.command,
      );
}
