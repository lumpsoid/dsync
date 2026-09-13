# Core implementation audit against SPEC.md

Date: 2026-09-13 · Commit: `f0e4f93` · Scope: everything under `lib/dsync_core/`

Baseline: `dart analyze` clean, `flutter test` 179/179 pass. Findings marked
**[confirmed]** were reproduced with a throwaway probe test, since deleted.

---

## Summary

The reconciliation table (§6) is implemented completely and correctly — all 16
cells, plus the same-hash short-circuit, type mismatch, and sorting. The
protocol framing, handshake, per-path archive commit, temp+rename write, and
empty-dir pruning all match the spec. The problems are concentrated in three
places: the **archive's crash/identity handling** (§8), the **remote channel's
error paths** (§4.2 vs §7.6), and the **ignore rules**, which are wired into the
scanner but nowhere else (§9).

Nothing in `lib/cli/` or `lib/app/` exists yet, which matches the commit
history; those gaps are listed at the end but not counted as defects.

---

## A. Data loss and correctness

### A1. An ignored path that is already in the archive is reported `deleted` **[confirmed]**

`Scanner.scan` (`lib/dsync_core/scan/scanner.dart:40-46`) synthesizes a
`deleted` entry for every archive path not in `context.seen`. Ignored paths are
`continue`d in `_walk` before ever being seen, so a file that is *still on disk*
but newly matched by an `ignore` rule is reported as deleted.

SPEC §9: "`ignore` rules: matching paths are **neither scanned nor deleted**."

Consequence: the moment an `--ignore` glob is added over an already-synced path,
the other replica sees `deleted / unchanged` → `deleteOnB`, and the file is
deleted there. The `--ignore` flag is additive on the initiator (§9) and is not
propagated to the remote side (see B3), so the rules are asymmetric by
construction — this is the normal case, not an edge case.

Fix direction: `Scanner` needs to distinguish "not present" from "not scanned".
The archive-diff loop must skip paths the ruleset ignores, and ideally `ScanEntry`
gains an `ignored` status so the reconciler can also refuse to act on them.

### A2. The archive header is never written to or read from the log

`JsonlArchiveStore` holds an `ArchiveHeader` passed at construction
(`lib/dsync_core/archive/jsonl_archive_store.dart:18`) and never persists it.
`load()` reads only `op`/`path`/`size`/`mtime`/`mode`/`hash` records.

SPEC §8.1: "Header: schema version, profile id, root path."

Consequences, in ascending severity:
- `schemaVersion` is a constant that can never be checked on load, so a format
  change has no migration or rejection path.
- Nothing detects that a profile's `rootPath` changed. Point a profile at a new
  directory and the old archive is replayed against it: every archived path is
  absent → all reported `deleted` → `deleted / unchanged` → **the entire tree is
  deleted on the other replica**.
- §11.5's exit 3 "archive unreadable" has no detection path at all.

### A3. A torn final log line makes the archive permanently unreadable **[confirmed]**

`load()` calls `jsonDecode` on every non-empty line
(`jsonl_archive_store.dart:60`). A crash partway through an append leaves a
partial JSON line; every subsequent run throws `FormatException` from `load()`,
which surfaces as a fatal error and requires manual repair.

This defeats the stated rationale of §8.2 ("per-path durable commits … trivially
inspectable") and of §7.3, whose crash-safety argument assumes the archive
survives a crash in a *readable* state. An append-only log should tolerate a
torn tail: drop a trailing unparseable line, fail on a malformed line anywhere
earlier.

### A4. `commitUpsert` is not durable against power loss

`_append` uses `IOSink.flush()` (`jsonl_archive_store.dart:119-126`), which
flushes Dart's buffers to the OS — not to disk. The class doc claims "a commit
that returns has survived a crash"; that holds for a process crash only.

SPEC §7.3 and §8.2 both rest on per-path durability. `RandomAccessFile.flush()`
issues a real `fsync` and is the drop-in replacement. Same gap in `compact()`,
which renames the temp file without fsyncing it first.

### A5. An abandoned `readFile` stream poisons the channel for the rest of the run **[confirmed]**

`RemoteAgent` multiplexes every operation over one `StreamIterator<Frame>`
(`lib/dsync_core/agent/remote_agent.dart:23`) and relies on the caller fully
draining `readFile`'s lazy stream. `Applier._copy` passes `source.readFile(path)`
straight into `dest.writeFile(...)`; if the destination write fails partway
(disk full, permission, remote error), the source's remaining `fileBytes` frames
are never consumed.

SPEC §7.6 requires the run to **continue** after a failed action. It does — and
the very next operation on that agent reads a leftover file-bytes frame and
tries to `jsonDecode` it:

```
FormatException: Unexpected character (at character 1)
```

Every remaining action against that replica then fails. One failed copy turns
into a whole-run failure against a remote replica.

Fix direction: on `readFile` abort, drain to the terminator frame before
returning; or give each request an id and resynchronize on it.

### A6. The same desync on the server side kills the connection

In `AgentServer._dispatch` (`lib/dsync_core/agent/agent_server.dart:56-66`), a
`writeFile` whose underlying agent call throws *before* consuming
`readByteStream(frames)` — e.g. `target.parent.create` fails — replies
`AgentFailure` while the client's already-sent byte frames sit unread. The serve
loop then treats them as requests. Note that `AgentRequest.fromFrame` is
evaluated as an *argument* to `_dispatch` (`agent_server.dart:21-28`), i.e.
outside its `try`, so the resulting `FormatException` escapes `serve` and tears
down the connection rather than being reported as a failed path.

### A7. The agent server accepts arbitrary peer-supplied paths

`LocalAgent._absolute` is `'$rootPath/$relativePath'`
(`lib/dsync_core/agent/local_agent.dart:115`) with no containment check, and
`AgentServer` forwards `request.params['path']` verbatim to `writeFile`,
`delete`, and `removeEmptyDirs`. A peer sending `../../.ssh/authorized_keys`
writes outside the replica root with the agent user's privileges. The spec
doesn't call this out, but an agent reached over ssh should not trust the far
end's paths. Normalize and reject any path that escapes the root.

---

## B. Spec conformance gaps

### B1. Skipped symlinks are never reported

SPEC §5.1: "Symlinks: **skipped and reported**, unless the path matches a
`follow` rule." `Scanner._walk` silently drops non-followed links
(`scanner.dart:68-71`), and no type in the core carries a "skipped" list —
`ScanEntry` has no such status and `scan()` returns only entries. A head has no
way to tell the user which links were ignored.

### B2. The post-rehash archive refresh never happens

SPEC §5.2 step 2: "Hash equals `E.hash` → unchanged; the archive entry's
`size`/`mtime` are **refreshed at commit**." The scanner does report the fresh
size/mtime on the `unchanged` entry, but the §6 table's `unchanged / unchanged`
cell is "nothing", so `Reconciler._resolveCell` returns without an action
(`lib/dsync_core/reconcile/reconciler.dart:75-76`) and `Applier` only commits for
actions. The refreshed values are computed and thrown away.

Consequence: a file whose mtime drifted but whose content didn't (a touch, a
restore from backup, a filesystem that rounds mtimes — the exact case §15.6
contemplates) is **re-hashed on every run, forever**. Directly against §1
"skip work whenever the stored state allows it".

This is a genuine conflict between §5.2 and the §6 table, not just a coding
slip — worth resolving in the spec. Cheapest fix: have the scanner refresh its
own archive entry when a rehash confirms equality, since that needs no
cross-replica coordination.

### B3. Ignore/follow rules never reach a remote replica

`RuleSet` exists and `Scanner` consumes it, but the `scan` protocol operation
carries no parameters (`remote_agent.dart:39-44`, `agent_server.dart:45-50`), and
nothing constructs a `RuleSet` from anything (no profile parser yet). A remote
agent therefore scans with whatever rules *its own process* was built with —
today, none.

SPEC §9: "Rules come from the profile file; `--ignore` may be repeated on the
command line and is additive." The profile lives on the initiator, so the rules
have to travel. Combined with A1, asymmetric rules actively delete files.

### B4. Hashing loads each file into memory twice, on the main isolate

```dart
final bytes = await file.readAsBytes();                              // main isolate
final digest = await Isolate.run(() => sha256.convert(bytes).toString());  // copied
```
`scanner.dart:187-189`. The read — the expensive part — is not off-loaded, and
`Isolate.run` copies the whole payload into the new isolate, so peak memory is
2× file size per in-flight job (×`jobs` concurrently). A multi-GB file OOMs the
process. §5.2 says "hashing runs in isolates"; the intent is clearly that the
*work* moves off the main isolate.

Fix direction: send the path into the isolate and stream-hash there
(`sha256.bind(File(path).openRead())`), keeping memory constant. A persistent
worker pool would also avoid spawning one isolate per file.

### B5. Nothing tears down the transport

`Agent` has no `close`/`disconnect`, `RemoteAgent` never calls `Channel.close()`,
and `RunController.run` unlocks but never closes. `SshChannel.close()` exists and
is unreachable from the run flow, so the spawned `ssh` process outlives the run.
§4.3's "releases at exit" is satisfied for the lock but not for the connection.
(`SshChannel.close()` also awaits `exitCode` with no timeout — a wedged remote
hangs the caller.)

### B6. §10's size warning has no data to work from

`PlanAction` carries only `path` and `type`; `Plan` carries no byte totals, and
`RunPlanEvent` carries only the `Plan`. A head cannot compute "total bytes to
transfer" without separately holding both scan lists, which `RunController` has
but doesn't expose.

### B7. §11.5 exit code 1 is not derivable from the events

Exit 1 is "some paths were **skipped** or are unresolved conflicts".
`RunSummaryEvent` reports applied/failed/conflict counts only
(`lib/dsync_core/models/run_event.dart:67-77`). `RunController` knows the skipped
count — `plan.actions.length - actionsToApply.length` — and drops it.

---

## C. Smaller issues

| # | Where | Issue |
|---|---|---|
| C1 | `models/location.dart:16-46` | Only absolute paths parse as local. `./notes`, `notes`, and `~/notes` all throw. §2 says a location "is either a local path or `user@host:path`" without restricting to absolute. |
| C2 | `jsonl_archive_store.dart:141`, `lock/replica_lock.dart:84` | `'${environment['HOME']}/.local/state'` yields the literal path `null/.local/state` when `HOME` is unset. CLAUDE.md calls exactly this shape a design error at a boundary — make the fallback explicit or fail loudly. |
| C3 | `jsonl_archive_store.dart:83`, `:89` | `_entries = {..._entries, ...}` copies the whole map on **every** commit — O(n²) bytes over a run. On a 100k-file tree that dominates the run. |
| C4 | `jsonl_archive_store.dart:119-126` | `_append` does `parent.create` + `openWrite` + `flush` + `close` per commit, i.e. reopens the log for every path. Hold one append handle for the run. |
| C5 | `local_agent.dart:71` | `Process.run('chmod', …)` spawns a process per copied file. Works and degrades correctly on Android, but it's the hot path of a large sync. |
| C6 | `scanner.dart:90-97` | A followed symlink pointing at one of its own ancestors recurses forever. No visited-inode guard. |
| C7 | `apply/applier.dart:105-113` | The destination archive records `sourceEntry.hash` against `metadata.size`, with no check that the two agree. A short write that somehow didn't throw would archive a hash that doesn't describe the bytes on disk. A `metadata.size == sourceEntry.size` assertion is nearly free. |
| C8 | `scanner.dart:112` | The fast path keys on size+mtime only (correct per §5.2), so a **mode-only** change is invisible forever — never detected, never propagated, never repaired. Worth stating explicitly in §7.4. |
| C9 | `protocol/ssh_channel.dart:36-42` | `_stderrLines` is a broadcast controller subscribed at construction; with no listener attached, stderr is discarded. Diagnostics from a failing `ssh` are lost unless someone subscribes first. |
| C10 | `models/rule_set.dart:70-78` | Character classes don't handle a leading `]` or backslash escapes inside the class. Minor vs. §9's "character classes". |
| C11 | `reconcile/reconciler.dart:67-72` | `entryA == null` + `entryB.status == modified` silently copies B→A. Defensible and documented, but "A has no record, B modified" is arguably a conflict, not a one-way mirror. Worth a decision in §6. |
| C12 | `local_agent.dart:56` | Fixed temp name `<target>.dsync.tmp`: two concurrent runs against the same replica collide. The lock (§4.3) prevents this today; a unique suffix removes the dependency. |

---

## D. Test gaps against §14

§14's own requirements are otherwise met — real temp dirs, the pure reconciler
table, the in-memory `Channel` round trip, and the §7.3 crash-safety test all
exist.

- The §6 cell **`modified / created`** has no test. Every other cell does.
- `scanner_test.dart`'s "an ignored file is excluded from the results" only
  covers a file with *no* archive entry — the A1 case is untested.
- §7.5's "directories that were already empty before the run are left alone" is
  untested. (The implementation happens to satisfy it: the loop only walks
  ancestors of a deleted path, which by definition were non-empty. Worth a test
  to keep it that way.)
- No test covers a mid-transfer failure over a `Channel` — the A5/A6 desync.

---

## E. Project-level deviations

- **SDK not pinned.** `pubspec.yaml:22` has `sdk: ^3.13.3`. SPEC §3: "Pinned
  Dart SDK version in `pubspec.yaml` of every package."
- **Core tests depend on Flutter.** Every file under `test/dsync_core/` imports
  `package:flutter_test`. The core *library* is clean, but `dart test` cannot run
  the core suite ("Could not find package `test`"), so §13's "`core` has no
  Flutter dependency" only half holds, and the v1 package split is blocked on
  rewriting all 18 test files. Switching them to `package:test` now is cheap.
- **Template leftovers.** `lib/main.dart` is the Flutter counter demo,
  `README.md` and `pubspec.yaml`'s `description` are still the generated text.
- **Directory naming.** `lib/dsync_core/` vs. §13's `lib/dsync-core/`. The
  underscore matches the eventual package name `dsync_core` and is the right
  call — update the spec rather than the code.

---

## F. Not yet built (consistent with the commit history)

Listed for completeness, not as defects:

- §11 CLI in full: `sync` / `agent --stdio` / `status`, all flags, interactivity,
  human and `--json` output, exit codes. Note that `SshChannel` spawns
  `dsync agent --stdio`, which has no entrypoint yet, so the SSH path cannot run
  end to end.
- §12 profile file — no TOML parsing, no `toml` dependency, nothing constructs a
  `RuleSet` or reads `warn_size_bytes`/`jobs`.
- §4.1 wiring — `Location.classify` exists, but nothing turns a `Location` into a
  `LocalAgent` or a `RemoteAgent`, and nothing gathers the local address set.
- §8.3 Android archive/lock locations (app private dir / Termux home).
- §13 `app/` skeleton.

---

## Suggested order of work

1. **A1 + B3** together — the ignore rules are the one place where the current
   code can silently destroy user data.
2. **A2, A3, A4** — the archive's identity and crash behavior; all three are
   local to `JsonlArchiveStore` and cheap.
3. **A5 + A6** — resynchronize the frame stream on an aborted transfer, and move
   `AgentRequest.fromFrame` inside `_dispatch`'s `try`.
4. **B4** — stream-hash inside the isolate before any large tree is attempted.
5. **B2** — decide the §5.2 / §6 conflict in the spec, then implement.
6. The rest as ordinary follow-up.
