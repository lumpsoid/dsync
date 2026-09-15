# dsync

Bidirectional file sync between two replicas, one run at a time. Nothing is
overwritten or deleted unless the reconciliation rules say it is safe or the
user confirmed it; work is skipped whenever the stored state allows it.

See [SPEC.md](SPEC.md) for the v0 specification — it is the source of truth for
behaviour, and every module's doc comments reference its section numbers.

## Status

v0, in development. The core engine and the CLI are implemented; the Flutter
head is not.

| Area | State |
|---|---|
| `lib/dsync_core/` — agent, scan, reconcile, apply, archive, protocol, rules | implemented |
| `lib/cli/` — args, profile, prompts, output | implemented |
| `lib/app/` — Flutter head | skeleton only (SPEC §16) |

## Using it

```sh
dsync sync <profile>              # the main one-shot run
dsync sync <locA> <locB>          # ad-hoc, no profile
dsync status <profile>            # scan + reconcile + print plan, apply nothing
dsync agent --stdio               # started by ssh on the remote host
```

A location is a local path, `user@host:path`, or `ssh://[user@]destination:path`;
in an ad-hoc pair the local one comes first. The `ssh://` form hands everything
up to the first `:` to `ssh` as its destination, unexamined — a `~/.ssh/config`
alias, `unix/run/ssh-unix-local/socket`, anything ssh accepts — and is always
remote, even when it leads back to this machine (SPEC §4.1). `--ssh-option`
passes an argv word to ssh itself, and `--remote-dsync` names the command that
starts the agent on the far side when the bare `dsync` is not on its PATH.

Profiles live in `$XDG_CONFIG_HOME/dsync/profiles/<name>.toml` (SPEC §12),
archives and locks in `$XDG_STATE_HOME/dsync/` (SPEC §8.3).

Every run prints a header naming both replicas and when the pair last synced,
before anything moves. `--dry-run` and `status` show the plan and apply
nothing; `--batch` applies without prompting but never resolves a conflict;
`--json` writes JSON Lines to stdout. See SPEC §11.2 for the full flag list
and §11.5 for the exit codes.

## Layout

A single Dart package for v0, split so the eventual move to separate packages
is a move rather than a rewrite (SPEC §13):

```
lib/
  dsync_core/   pure Dart: agent, scan, reconcile, apply, archive, protocol, rules
  cli/          args parsing, TTY prompts, output formatting
  app/          Flutter head
```

`dsync_core/` depends on nothing head-specific and has no Flutter dependency —
its tests run under plain `dart test`.

## Development

```sh
flutter pub get
dart analyze
dart test            # core suite, no Flutter required
flutter test         # everything, including the Flutter head
```
