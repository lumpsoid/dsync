import 'package:args/command_runner.dart';
import 'package:dsync/dsync_core/state_dir.dart';

/// `--state-dir <path>` (SPEC §8.3, §11.2, task af1128): the explicit
/// override of where this invocation keeps its state — the archive logs and
/// their locks, this device's identity, and the paired-device store.
///
/// Without it, SPEC §8.3's platform rules decide
/// (`lib/dsync_core/state_dir.dart`), unchanged. With it, that directory is
/// used verbatim ([ExplicitStateDir]).
///
/// **Why it exists.** Two `dsync agent --serve` processes on one host are a
/// real arrangement — one per replica set, one per service user — and
/// without an override they share a state directory, which means they share
/// a paired-device store and contend for the same per-profile locks (SPEC
/// §4.3). Instance-scoped state is what makes them independent. It also
/// makes a service unit self-describing: a packager reading `ExecStart` sees
/// where state lives without having to know what XDG is, and dsync itself
/// gets none of that for free — see `contrib/README.md`.
///
/// **Why a flag and not an environment variable.** There is deliberately no
/// `DSYNC_STATE_DIR`. `XDG_STATE_HOME`, `HOME` and `LOCALAPPDATA` are
/// platform conventions shared with everything else on the box, so a service
/// that sets `XDG_STATE_HOME` for a whole slice should keep getting exactly
/// the CLI's own behaviour out of dsync; a dsync-specific variable beside
/// them would be a second, invisible answer to the same question. One
/// explicit override, and §8.3's documented rules underneath it.
///
/// **Why per-command rather than one global option on `DsyncCommandRunner`.**
/// Two reasons, and the first is the deciding one.
///
/// - It applies to exactly the commands that address *this host's* state
///   directory — `agent`, and the `pair` and `archive` subcommands, which
///   are precisely the commands already taking a [StateDirPlatform]. It
///   would be ambiguous on `sync`/`status`: a run has two sides, each
///   resolving its own state directory on its own host (a remote side
///   through its own `dsync agent` invocation, which is where its
///   `--state-dir` belongs), so a single value there would silently mean
///   only the local ones. Per-side overrides are a profile's job, not a
///   flag's, and are not invented here.
/// - `package:args` puts a [CommandRunner]'s own options *before* the
///   command word, so a global would have to be written `dsync --state-dir
///   /var/lib/dsync/media agent --serve` — the flag reads as if it modified
///   `dsync` rather than the agent it scopes, in the one place (an
///   `ExecStart` line) this flag exists to be read.
///
/// Mixed into a [Command] rather than written out nine times: the flag name,
/// its help text and the empty-value rule are one fact, and a read site
/// looks the option up by string ([ArgResults.option]), where a typo is not
/// a compile error (the reason `CommonSyncFlags` names its flags in one
/// place too, task 4fce5d).
mixin StateDirOption on Command<int> {
  static const optionStateDir = 'state-dir';

  /// Registers `--state-dir` on this command. Called from the constructor,
  /// beside whatever other options the command registers.
  ///
  /// No `defaultsTo`: the default is SPEC §8.3's rules, which are a
  /// computation over this host and its environment rather than a string
  /// this parser could hold, and "not given" has to stay distinguishable
  /// from "given" for [stateDirOr] to leave those rules alone.
  void addStateDirOption() {
    argParser.addOption(
      optionStateDir,
      valueHelp: 'path',
      help:
          'Keep this invocation\'s state here — archive logs and their '
          'locks, this device\'s identity, the paired-device store — '
          'instead of the platform default (SPEC §8.3: '
          '\$XDG_STATE_HOME/dsync, ~/Library/Application Support/dsync, '
          '%LOCALAPPDATA%\\dsync). Used verbatim, created if missing. Two '
          'agents on one host need different ones, or they share a '
          'paired-device store and contend for the same locks.',
    );
  }

  /// This invocation's state-directory rule: `--state-dir`'s value if it was
  /// given, otherwise [platformDefault] — the SPEC §8.3 case this command
  /// was constructed with.
  ///
  /// Call it once in `run()` and thread the result on, rather than reading
  /// the field the command was built with: the field is the *default*, and
  /// every state-resolving call in that command has to see the same answer.
  ///
  /// An empty value is a usage error rather than an [ArgumentError] out of
  /// [ExplicitStateDir] — `--state-dir=` is a mistyped argument, which is
  /// the bucket [usageException] and SPEC §11.5's exit 3 exist for.
  StateDirPlatform stateDirOr(StateDirPlatform platformDefault) {
    final path = argResults!.option(optionStateDir);
    if (path == null) return platformDefault;
    if (path.isEmpty) {
      usageException(
        '--state-dir needs a path. An empty one would put this host\'s '
        'archive logs, locks and paired-device store in whatever directory '
        'this process was started in.',
      );
    }
    return ExplicitStateDir(path);
  }
}
