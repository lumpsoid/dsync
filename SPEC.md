# Bidirectional File Sync — v0 Specification

Working name: `dsync` (placeholder, rename freely).

## 1. Goals and non-goals

**Goals**
- Bidirectional synchronization of regular files between two replicas.
- No data loss: nothing is overwritten or deleted unless the reconciliation rules say it is safe or the user explicitly confirmed it.
- Minimal resource use: skip work whenever the stored state allows it.
- Same core engine drives a CLI and, later, a Flutter app.

**Non-goals for v0**
- Continuous / watch mode.
- Delta (partial-file) transfer.
- Ownership, ACLs, extended attributes.
- More than two replicas per run.
- Any transport other than in-process or SSH.

## 2. Concepts

- **Replica** — a directory tree at a location. A location is either a local path or `user@host:path`.
- **Root** — the top directory of a replica. All paths are relative to the root.
- **Profile** — a named pair of replicas plus options (ignore rules, thresholds). Lives in a TOML file.
- **Agent** — the component that has direct filesystem access to one replica. Every replica is accessed through an agent, whether local or remote.
- **Archive** — per-replica record of the state of every synced file as of the last successful propagation for that path.
- **Run** — one invocation: connect to both agents, scan, reconcile, present, apply, exit.

## 3. Platforms and heads

- Targets: Linux, Android.
- Heads: `cli` (Linux; Android via Termux) and `app` (Flutter, Android). Both depend on `core`; `core` has no Flutter dependency.
- Pinned Dart SDK version in `pubspec.yaml` of every package.
- Android note: Android's shared ("external") storage does not preserve POSIX permission bits and is case-insensitive. The engine must not fail when a metadata write is rejected (see §7.4), and must record the *actual* post-write state in the archive rather than the intended one. Whether mtime can be set on a given Android path is verified on the device early in development; the archive rule above keeps the engine correct either way.

## 4. Replica access

### 4.1 Location resolution
A location `user@host:path` is resolved before the run. If `host` is `localhost`, an address of this machine, or absent, the agent runs **in-process**. Otherwise the agent runs as a **remote process**. Both cases use the same `Agent` interface; the caller does not know which one it got.

### 4.2 Remote agent
- The same binary is installed on the remote host and started as `dsync agent --stdio` over `ssh`.
- v0 transport: spawn the system `ssh` executable. The channel is a bidirectional byte stream; the transport is behind a `Channel` interface so a Dart SSH client or a plain socket can replace `ssh` later (needed for the Flutter head, which cannot rely on a system `ssh` binary — deferred).
- Protocol: framed messages over the stream. Frame = 1 byte type + 4 byte big-endian length + payload. Type `0` = UTF-8 JSON control message, type `1` = raw file bytes. First exchange is a version handshake; mismatched protocol versions abort the run.
- Agent operations: `hello`, `lock`, `unlock`, `scan`, `readFile` (streamed), `writeFile` (streamed, temp + rename, set mtime/mode), `delete`, `removeEmptyDirs`, `archiveCommit`.

### 4.3 Locking
Each agent takes a lock file in its state directory for the replica before scanning and releases it at exit. A held lock aborts the run with a fatal error.

## 5. Scan and change detection

Each agent scans its own replica and compares against **its own archive**. It returns a list of entries with a status relative to the archive, so the initiator never needs the full archive of the other side.

### 5.1 What is scanned
- Regular files only. Directories are traversed but not tracked as entries.
- Symlinks: skipped and reported, unless the path matches a `follow` rule (§9), in which case the link is resolved and the target is treated as if it were at the link's path.
- Hardlinks: treated as independent regular files.
- Paths matching an `ignore` rule are not scanned.

### 5.2 Fast path
For each file, with archive entry `E`:
1. If `size` and `mtime` equal `E.size` and `E.mtime` → **unchanged**, no hash computed.
2. Otherwise compute the content hash.
   - Hash equals `E.hash` → **unchanged**; the archive entry's `size`/`mtime` are refreshed at commit.
   - Hash differs → **modified**, new hash reported.
3. File present, no archive entry → **created**, hash computed and reported.
4. Archive entry present, file absent → **deleted**.

Hash: SHA-256, via `package:crypto`. Hashing runs in isolates, parallelism configurable.

`mtime` is stored as microseconds since epoch as returned by `FileStat`. Comparison is exact equality.

## 6. Reconciliation

Done on the initiating side from the two status lists. Per path, with statuses on replicas A and B:

| A \ B | unchanged | created | modified | deleted |
|---|---|---|---|---|
| **unchanged** | nothing | copy B→A | copy B→A | delete on A |
| **created** | copy A→B | same hash: commit only; else **conflict** | same hash: commit only; else **conflict** | **conflict** |
| **modified** | copy A→B | same hash: commit only; else **conflict** | same hash: commit only; else **conflict** | **conflict** |
| **deleted** | delete on B | **conflict** | **conflict** | commit only |

Additional rules:
- **Same content, no transfer.** Whenever both sides currently hold the same hash, no bytes move; both archives are committed with the current state.
- **Type mismatch.** A file at `P` on one side and a directory containing files at `P` on the other is a conflict on `P`.
- **Conflicts are never auto-resolved.** They are presented to the user, who picks a direction or skips.
- **Deletions are actions.** A propagated deletion appears in the plan like any other action and can be vetoed per item in interactive mode.

The output of reconciliation is a **plan**: an ordered list of actions (`copy A→B`, `copy B→A`, `delete on A`, `delete on B`, `commit-only`) plus a list of conflicts.

## 7. Applying the plan

### 7.1 Order
Actions are applied one path at a time. Copies before deletions is not required; the archive rule in §7.3 makes order irrelevant for correctness.

### 7.2 Copy
1. Source agent streams the file; destination agent writes to a temp file in the same directory as the target (so rename is atomic on the same filesystem).
2. Destination sets mtime to the source mtime and mode bits to the source mode (§7.4).
3. Destination renames temp over target. Parent directories are created as needed.
4. Destination stats the final file and returns the resulting `size`, `mtime`, `mode`.

### 7.3 Archive commit per path
After an action succeeds on both sides, **both** agents commit the entry for that path immediately. A crash between the two commits leaves one side's archive stale; on the next run that side reports the path as modified with the same hash as the other side, which resolves as commit-only (§6). No work is redone beyond one hash.

### 7.4 Metadata
- `mtime`: always propagated. If setting it fails, the write still succeeds; the actual mtime is what gets archived.
- Mode bits: propagated on a best-effort basis; failure is logged, not fatal.
- Ownership, xattrs: not touched.

### 7.5 Delete
Target file is deleted. Then every ancestor directory up to the root that the tool has just emptied is removed. Directories that were already empty before the run are left alone — the tool only removes emptiness it created.

### 7.6 Failures
A failed action is recorded, the path is left in whatever state it reached (temp files are cleaned up), and the run continues with the next action. Failed paths are reported at the end and contribute to the exit code.

## 8. Archive

### 8.1 Content
One archive per replica, on the host of that replica, keyed by profile id + replica side. Header: schema version, profile id, root path. Entry: `path`, `size`, `mtime`, `mode`, `hash`.

### 8.2 Format (default chosen, see §15)
Append-only JSON Lines log. Each commit appends one line (an upsert or a tombstone) and flushes. At the end of a run that reached the apply phase, the log is compacted into a fresh file and swapped in by rename. On load, the log is replayed; last write per path wins.

Rationale: per-path durable commits (§7.3) without rewriting the whole file, no native dependency, trivially inspectable. The archive sits behind an `ArchiveStore` interface so a SQLite implementation can replace it if the log approach proves inadequate on large trees.

### 8.3 Location
- Linux: `$XDG_STATE_HOME/dsync/` (default `~/.local/state/dsync/`).
- Android: the app's private files directory (Flutter head) or Termux's home (CLI head).

## 9. Ignore and follow rules

- Syntax: glob, matched against the root-relative path. Supported: `*`, `?`, `**`, character classes. No negation in v0.
- `ignore` rules: matching paths are neither scanned nor deleted.
- `follow` rules: matching symlinks are resolved (§5.1).
- Rules come from the profile file; `--ignore` may be repeated on the command line and is additive.

## 10. Size warning
Optional `warn_size_bytes` in the profile (`--warn-size` flag). If the total bytes to transfer in the plan exceed it, the plan display shows a warning. Nothing is blocked.

## 11. CLI

### 11.1 Commands
```
dsync sync <profile> [flags]      # the main one-shot run
dsync sync <locA> <locB> [flags]  # ad-hoc, no profile
dsync agent --stdio               # started by ssh on the remote host
dsync status <profile>            # scan + reconcile + print plan, apply nothing
```
`status` is `sync --dry-run` under a friendlier name.

### 11.2 Flags
```
--dry-run             show plan, apply nothing
--batch               apply non-conflicting actions without asking;
                      conflicts are listed, not resolved
--json                machine-readable output (JSON Lines) on stdout
--ignore <glob>       additive to profile
--warn-size <bytes>
--jobs <n>            hash parallelism
--verbose / --quiet
```

### 11.3 Interactivity
Default is interactive: the plan is shown, conflicts first, then each proposed action; the user accepts, skips, or picks a direction per item, or accepts all remaining. `--batch` skips the prompts for non-conflicts. With `--batch`, conflicts are never resolved automatically.

### 11.4 Output
- Human mode: a plan table, then progress lines during apply, then a summary (applied / skipped / conflicts / failed).
- `--json`: one JSON object per line with a `type` field (`plan`, `action`, `conflict`, `progress`, `result`, `summary`, `error`). Human text goes to stderr in this mode so stdout stays parseable.

### 11.5 Exit codes
```
0  all planned actions applied, no conflicts
1  completed, but some paths were skipped or are unresolved conflicts
2  completed, but some actions failed
3  fatal: bad arguments, cannot reach a replica, lock held, archive unreadable,
   protocol version mismatch
```
When both 1 and 2 apply, 2 wins.

## 12. Profile file

TOML, parsed with `package:toml`. Location: `$XDG_CONFIG_HOME/dsync/profiles/<name>.toml` (Linux), app config dir (Android).

```toml
[replicas]
a = "/home/me/notes"
b = "me@phone:/sdcard/notes"

[rules]
ignore = ["**/.git", "*.tmp", "**/node_modules"]
follow = ["shared"]

[options]
warn_size_bytes = 500_000_000
jobs = 4
```
Command-line flags override profile options. `ignore` is additive.

## 13. Project layout

For v0 the code lives in a **single Dart package** for development ergonomics.
The structure is organized so the eventual split into separate packages is a
move, not a rewrite:

```
lib/
  dsync-core/    pure Dart: agent, scan, reconcile, apply, archive, protocol, rules
  cli/           args parsing, TTY prompts, output formatting — everything CLI-specific
  app/           Flutter head; deferred beyond skeleton
```

`dsync-core/` holds all core code and depends on nothing head-specific.
`cli/` holds everything specific to the CLI experience and depends on
`dsync-core/`. `app/` will do the same for the Flutter head.

The `dsync-core` boundary exposes: `Location`, `Agent` (+ `LocalAgent`,
`RemoteAgent`), `Channel`, `Scanner`, `Reconciler`, `Plan`, `Applier`,
`ArchiveStore`, `RuleSet`, and a `RunController` that drives a run and emits
events the heads render.

At v1 (or whenever the ergonomics of one package start to hurt), each top-level
folder becomes its own package — `dsync_core`, `dsync_cli`, `dsync_app` — with
the same boundaries already enforced by the folder split.

## 14. Testing

- Core logic is tested against real temporary directories created per test.
- Reconciliation is additionally tested as a pure function on hand-built status lists covering every cell of the table in §6.
- The protocol is tested by running a `LocalAgent` behind an in-memory `Channel`, exercising the same `RemoteAgent` code path as SSH without a network.
- Crash-safety of §7.3 is tested by killing the apply between the two commits and re-running.

## 15. Defaults chosen where you were undecided

Override any of these before code starts:
1. **Symlinks**: skipped unless matched by a `follow` rule; hardlinks treated as plain files.
2. **Archive format**: JSON Lines append log with compaction, behind an interface. Alternative: SQLite via `package:sqlite3` (adds a native dependency on both hosts).
3. **Protocol encoding**: length-prefixed JSON frames. Alternative: MessagePack (`package:msgpack_dart`), same framing.
4. **Exit codes**: as in §11.5, mirroring Unison's four-level scheme.
5. **Profile format**: TOML.
6. **mtime comparison**: exact equality of microsecond values. If a target filesystem turns out to round mtimes, the archive stores the rounded value it reads back, so the next run's fast path still matches.

## 16. Deferred

- Flutter head beyond a skeleton that compiles against `core`.
- Transport for the Flutter head (Dart SSH client or a TCP listener mode of the agent).
- Watch mode.
- Delta transfer (librsync via FFI or a Dart implementation).
- Negated ignore patterns.
- Ownership / xattr preservation.
- Case-insensitivity and Unicode-normalization handling beyond "whatever the filesystem does".
