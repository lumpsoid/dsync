# Contributing to dsync

Thanks for wanting to help. dsync is a small personal project, so the process
is light.

## Before you write code

Ideally a change starts as an issue: open a
[proposal](https://github.com/lumpsoid/dsync/issues/new?template=proposal.yml)
or a [bug report](https://github.com/lumpsoid/dsync/issues/new?template=bug_report.yml),
we agree on the shape, and then a pull request links it (`Closes #123`). That
saves you from writing something that doesn't fit. This is a wish, not a rule:
small, obvious fixes like a typo, a broken link or a one-line bug fix can go
straight to a pull request.

## Setup

You need a Rust toolchain from [rustup](https://rustup.rs) (stable) and
Flutter 3.47.9, the release that bundles the Dart SDK `pubspec.yaml` pins.

```sh
git clone https://github.com/lumpsoid/dsync.git && cd dsync
flutter pub get
scripts/check.sh
```

Building for Android also needs the NDK; see SPEC §13.

## Where a change goes

[SPEC.md](SPEC.md) is the source of truth for behaviour, and the code's doc
comments cite its sections. A change in behaviour updates the SPEC in the same
pull request. [CLAUDE.md](CLAUDE.md) holds the code principles every change
follows. In short:

- `native/domain/`: pure rules and values. No I/O and no tokio; CI enforces it.
- `native/core/`: everything with I/O, meaning stores, transports, the
  protocol, pairing, and `Run`, which owns the order of a sync.
- `native/cli/`: the `dsync` binary, with argument parsing, rendering and
  prompts.
- `native/hub/`: the bridge the Flutter app talks to. After editing
  `native/hub/src/signals.rs`, regenerate and commit the Dart bindings under
  `lib/app/rust/bindings/` (SPEC §13 has the `rinf gen` invocation).
- `lib/app/`: the Flutter app.

## Gates

`scripts/check.sh` runs every check CI runs, in the same order: `dart analyze`,
`flutter test`, `cargo fmt --check`, clippy with `-D warnings`, the workspace
build and tests, and the check that `dsync-domain` stays free of tokio. A pull
request is ready when it passes. New behaviour comes with a test.

## Commits

Use [Conventional Commits](https://www.conventionalcommits.org/):
`type(scope): description`, for example `fix(core): keep the lock on a failed
commit`. Types in use: `feat`, `fix`, `perf`, `docs`, `test`, `build`, `ci`,
`chore`. A change users will notice gets a line under `## [Unreleased]` in
[CHANGELOG.md](CHANGELOG.md).

## License

By contributing you agree that your contribution is licensed under the
project's [MIT license](LICENSE).
