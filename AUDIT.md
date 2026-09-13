# Core audit against SPEC.md — resolution record

Audited at `f0e4f93`, resolved across the 31 commits below. Every finding's
reasoning lives in the body of the commit that fixed it; this file is only the
index from finding to commit.

`dart analyze` clean; 263 tests pass under both `dart test` (core alone, no
Flutter) and `flutter test`.

## Data loss and correctness

| Finding | Commit |
|---|---|
| A1 — an ignored path already in the archive scanned as deleted, propagating a deletion of a file still on disk | `b91a8d1` |
| A2 — the archive header was never persisted, so nothing detected a repointed root or an older schema | `bc3bed4` |
| A3 — a half-written last line made the archive permanently unreadable | `c45317e` |
| A4 — commits flushed Dart's buffers but never fsynced, so §7.3's durability did not hold | `44d03d8` |
| A5 — an abandoned `readFile` left frames queued and poisoned the channel for the rest of the run | `232f5fe` |
| A6 — a failed `writeFile` and a malformed frame each tore down the agent session | `d10b757` |
| A7 — the agent joined peer-supplied paths onto its root with no containment check | `ae2cbe5` |

## Spec conformance

| Finding | Commit |
|---|---|
| B1 — skipped symlinks were never reported (§5.1) | `88a0638` |
| B2 — the post-rehash archive refresh never happened, so drifted files rehashed forever (§5.2) | `bbaa72c` |
| B3 — ignore/follow rules never reached a remote replica (§9) | `90c4180` |
| B4 — hashing read each file whole, on the calling isolate, then copied it (§5.2) | `2e14a7e` |
| B5 — nothing tore down the transport, so the `ssh` process outlived the run | `21d6380` |
| B6 — the plan carried no byte totals, so §10's size warning had no input | `52ec24c` |
| B7 — no skipped count, so §11.5's exit 1 was not derivable | `37be1c5` |

## Smaller issues

| Finding | Commit |
|---|---|
| C1 — only absolute paths parsed as local locations | `0ea10a8` |
| C2 — an unset `HOME` produced a path containing the string `null` | `e1a0aa1` |
| C3 — every commit copied the whole entries map | `f0fc628` |
| C4 — every commit re-created the state directory and stat-ed the log | `72cd0b3` |
| C5 — a `chmod` process spawn per copied file | `91f33b0` |
| C6 — a followed symlink aimed at an ancestor recursed forever | `1af899e` |
| C7 — a short transfer was archived under a hash that did not describe it | `249a982` |
| C8 — mode-only drift is never detected (documented, not fixed) | `b6e6283` |
| C9 — ssh stderr was dropped when nothing was listening | `7f4a8ce` |
| C10 — glob classes mishandled a leading `]` and leaked regex syntax | `0935dc5` |
| C11 — "a path one side has never seen" was an undocumented extension (decided in §6) | `1beb002` |
| C12 — a fixed scratch filename, and scratch files were scannable | `bb17772` |

## Test and project-level

| Finding | Commit |
|---|---|
| D — §14 gaps: the `modified / created` cell, and §7.5's already-empty directory | `32816ee` |
| E1 — the Dart SDK was a caret range, not pinned (§3) | `062a87a` |
| E2 — core tests imported `package:flutter_test`, so the core suite needed Flutter (§13) | `0a55e86` |
| E3 — README, pubspec description, `main.dart` and the widget test were `flutter create` scaffolding | `62078e8` |
| E4 — §13 wrote the core directory as `dsync-core` while the code used `dsync_core` | `f13fed5` |

## Spec amendments

Four findings were resolutions of gaps or conflicts in SPEC.md rather than in
the code, so the spec changed alongside it:

- §5.1 / §11.4 — skipped symlinks are reported, and `symlink` joins the
  `--json` type list (`88a0638`).
- §6 — a path one side has never seen is mirrored, not treated as a conflict
  (`1beb002`).
- §7.4 — mode bits travel with content and never on their own (`b6e6283`).
- §13 — the core directory is `dsync_core` (`f13fed5`).

Two further conflicts were resolved in favour of the spec without amending it:
§5.2's post-rehash refresh, which the §6 table's `unchanged / unchanged` cell
had silently defeated (`bbaa72c`), and §9's "neither scanned nor deleted",
which the archive diff contradicted (`b91a8d1`).

## Still not built

Unchanged from the audit, and not defects: the §11 CLI in full (including the
`dsync agent --stdio` entrypoint that `SshChannel` spawns), the §12 TOML
profile, the §4.1 wiring that turns a `Location` into an `Agent`, §8.3's
Android state locations, and the §13 `app/` head beyond the skeleton that now
compiles against `dsync_core`.
