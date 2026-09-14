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
- `hello` carries the replica this connection should serve (root path — unexpanded — profile id, side, job count) and replies with that replica's archive last-commit time (or `null`), since the initiator cannot `stat` an archive on the remote host.

### 4.3 Locking
Each agent takes a lock file in its state directory for the replica before scanning and releases it at exit. A held lock aborts the run with a fatal error.

## 5. Scan and change detection

Each agent scans its own replica and compares against **its own archive**. It returns a list of entries with a status relative to the archive, so the initiator never needs the full archive of the other side.

A path the scan cannot read — permission denied, or the entry vanished between the directory listing and the read — is **recorded and skipped, and the scan continues with the rest of the tree**, mirroring the per-path tolerance §7.6 gives the apply phase. One locked file does not cost the run. Such a path produces no status entry, for the same reason a skipped symlink does not (§5.1): a path the scan could not read has no state relative to the archive, so there is no cell of §6's table it belongs in. It is reported alongside skipped symlinks and contributes to the exit code (§11.5).

Archive entries beneath a directory whose listing failed are **not** reported `deleted`. The scan never got to look, so their absence from the walk is not evidence they are gone; reporting them would propagate a deletion the user never made to the other replica.

Silence is not enough on its own, though. An unreadable path is reported to reconciliation as well, and excluded there (§6) — because §6 reads a side's silence about a path as "this side has never seen it", which means *mirror it from the other side*. That is the right reading for a path that is genuinely absent and the wrong one for a path that is present and merely unread: it would overwrite a locally-edited file the scan could not look at, on a run that just said the path was not synced. An unreadable directory covers every path beneath it for this purpose, since the directory is what the scan reports but the files are what it hid.

The replica **root** is the exception: if the root itself cannot be listed, that is fatal (§11.5 exit 3), not a per-path skip. There is no tree left to sync, and reporting an empty one would invite mirroring the entire other replica into a directory this host cannot read.

### 5.1 What is scanned
- Regular files only. Directories are traversed but not tracked as entries.
- Symlinks: skipped and reported, unless the path matches a `follow` rule (§9), in which case the link is resolved and the target is treated as if it were at the link's path. A `follow` link that is broken, or whose target is neither a regular file nor a directory, is also reported as skipped. Reported paths travel alongside the status list and surface as `symlink` lines (§11.4); they are not status entries, since a skipped link has no state relative to the archive to reconcile.
- Unreadable paths: reported the same way, as `unreadable` lines (§11.4), carrying the OS's own reason — "permission denied" and "no such file or directory" are what tell a locked file apart from one that vanished mid-scan, and the latter is not there to inspect afterwards. Unlike a skipped symlink, which is the tool obeying §9's rules and happens identically on every run, an unreadable path is a failure and counts toward exit 1.
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
- **A path one side has never seen.** The table assumes both replicas report a status for every path. A replica with neither the file nor an archive entry for it reports nothing at all — the normal state of a fresh replica being set up against an established one, and of any path that is new to this pair. Such a path is mirrored from whichever side has it, whatever status that side gives it — or, when that side reports `deleted`, tombstoned on the side that still records it, so the two archives converge instead of drifting apart forever. Silence is what makes that safe: a replica that still had the file on disk would report `created` even against a wiped archive, so silence from one side plus a `deleted` report from the other means the path is gone everywhere. It is not a conflict: treating it as one would make the first run against an empty directory conflict on every file, and treating a still-pending deletion as one would ask the user to resolve a deletion that has already finished everywhere.
- **A path a scan could not read.** Excluded entirely: no action, no conflict. The table needs a status from both sides, and the unreadable side has none to give — its silence would otherwise be read as the "never seen" rule above and mirror the other side's copy over a file the tool was never able to look at. Not a conflict either: asking the user to choose between one side's content and something that was never read is not a choice they can make. The path is reported (§5.1) and counts toward exit 1 (§11.5); the next run reconciles it normally once it can be read.
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
After an action succeeds on both sides, **both** agents commit the entry for that path immediately. A crash between the two commits leaves one side's archive stale.

For a copy, that self-heals: the stale side reports the path as modified with the same hash as the other side, which resolves as commit-only (§6). No work is redone beyond one hash.

For a delete, the same crash does not self-heal the same way — there is no shared hash for the two sides to agree on. The side whose commit landed has no file and no archive entry left, so it reports nothing; the side whose commit was lost still holds its stale pre-delete entry, so it reports `deleted`. §6's "a path one side has never seen" rule is what closes this gap: silence from the landed side plus `deleted` from the stale side tombstones the stale side's entry, so the next run converges on both archives agreeing the path is gone, rather than leaving one side reporting a deletion that already finished everywhere.

### 7.4 Metadata
- `mtime`: always propagated. If setting it fails, the write still succeeds; the actual mtime is what gets archived.
- Mode bits: propagated on a best-effort basis; failure is logged, not fatal.
- Mode bits travel with content, never on their own. The fast path (§5.2) keys on size and mtime, so a file whose permissions changed and whose content did not scans as `unchanged` and gets no action. A mode-only difference between the replicas is therefore never detected and never repaired; it is corrected the next time that file's content changes. Detecting it would mean comparing the scanned mode against the archived one and adding a metadata-only action, which v0 does not have.
- Ownership, xattrs: not touched.

### 7.5 Delete
Target file is deleted. Then every ancestor directory up to the root that the tool has just emptied is removed. Directories that were already empty before the run are left alone — the tool only removes emptiness it created.

### 7.6 Failures
A failed action is recorded, the path is left in whatever state it reached (temp files are cleaned up), and the run continues with the next action. Failed paths are reported at the end and contribute to the exit code.

## 8. Archive

### 8.1 Content
One archive per replica, on the host of that replica, keyed by profile id + replica side. Header: schema version, profile id, root path. Entry: `path`, `size`, `mtime`, `mode`, `hash`.

### 8.2 Format (default chosen, see §15)
Append-only JSON Lines log. Each commit appends one line (an upsert or a tombstone) and flushes. At the end of a run that reached the apply phase, the log is compacted into a fresh file and swapped in by rename. A run that committed nothing does not compact. On load, the log is replayed; last write per path wins.

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
- Human mode: a run header naming both replicas and when the pair last synced, then a plan table, then progress lines during apply, then a summary (applied / skipped / conflicts / failed / unreadable). The header prints before anything moves, so a mistyped location is caught while it is still harmless; when either side has no archive it says so, because that run mirrors rather than propagating deletions (§6). `skipped` counts proposed actions the user declined; `unreadable` counts paths §5 could not read, which were never proposed at all — two different questions, so two different numbers.
- `--json`: one JSON object per line with a `type` field (`replicas`, `plan`, `action`, `conflict`, `symlink`, `unreadable`, `scanTally`, `progress`, `result`, `summary`, `error`). `symlink` reports a link the scan skipped (§5.1); `unreadable` reports a path it could not read (§5), with the OS's reason in `detail`. They are separate types rather than one type with a `reason` field, so a consumer already filtering for `symlink` — a thing that is normal on every run — does not silently start matching failures too. `scanTally` reports, per side, how many scanned paths resolved through each of §5.2's branches — most usefully `metadataMatched` against `hashMatched`, the fast path against the rehash it took to prove an unchanged file's drifted size or mtime meant nothing. `replicas` is the header's data — each side's location, locality, archive path and last-commit time, plus the profile id and `firstSync` — as facts only; the human warning is a rendering of `firstSync`, not a string on the wire. Human text goes to stderr in this mode so stdout stays parseable.

### 11.5 Exit codes
```
0    all planned actions applied, no conflicts
1    completed, but some paths were skipped (including paths the scan could
     not read, §5) or are unresolved conflicts
2    completed, but some actions failed
3    fatal: bad arguments, cannot reach a replica, lock held, archive unreadable,
     protocol version mismatch
130  interrupted by SIGINT (128 + 2)
143  interrupted by SIGTERM (128 + 15)
```
When both 1 and 2 apply, 2 wins. 130/143 are deliberately outside the 0-3
scheme: they say what the user did, not what the run did, so they win over
any of 0-3 rather than being ranked against them — folding an interrupt into
3 would have retry logic retrying a run the user asked to stop.

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
  dsync_core/    pure Dart: agent, scan, reconcile, apply, archive, protocol, rules
  cli/           args parsing, TTY prompts, output formatting — everything CLI-specific
  app/           Flutter head; deferred beyond skeleton
```

`dsync_core/` holds all core code and depends on nothing head-specific.
`cli/` holds everything specific to the CLI experience and depends on
`dsync_core/`. `app/` will do the same for the Flutter head.

The `dsync_core` boundary exposes: `Location`, `Agent` (+ `LocalAgent`,
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
