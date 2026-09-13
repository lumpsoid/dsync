# dsync

Bidirectional file sync between two replicas, one run at a time. Nothing is
overwritten or deleted unless the reconciliation rules say it is safe or the
user confirmed it; work is skipped whenever the stored state allows it.

See [SPEC.md](SPEC.md) for the v0 specification — it is the source of truth for
behaviour, and every module's doc comments reference its section numbers.

## Status

v0, in development. The core engine is implemented; the CLI and the Flutter
head are not yet.

| Area | State |
|---|---|
| `lib/dsync_core/` — agent, scan, reconcile, apply, archive, protocol, rules | implemented |
| `lib/cli/` — args, prompts, output | not started |
| `lib/app/` — Flutter head | skeleton only (SPEC §16) |

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
