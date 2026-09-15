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

- **Replica** — a directory tree at a location. A location is a local path, `user@host:path`, `ssh://[user@]destination:path`, or `unix://<socket-path>:<replica-path>`.
  - The first two are told apart by ssh's and rsync's own rule: a colon separates a host from a path only when it comes before the first `/`. That keeps `./log:old` a local path, and it is why `notes` is a relative path rather than a host.
  - That rule can only describe a destination shaped like a hostname, and `ssh` reaches plenty that are not: a `~/.ssh/config` `Host` alias, a `.host` name, `unix/run/ssh-unix-local/socket` for a socket-activated sshd. `ssh://` means "this one is for ssh, hands off": everything between the scheme and the first `:` is handed to `ssh` as its destination, verbatim, slashes included — which is why the colon separates it from the path and a `/` cannot.
  - `unix://` is the same shape for the transport that needs no `ssh` at all: everything between the scheme and the first `:` is the filesystem path of a socket a `dsync agent --listen` is already bound to (§4.2). Both halves are full of slashes, so only a colon could separate them. No `user@` is split off — there is no user to name, because what decides whether the connection is made is whether the process can open the socket, which is the filesystem's answer. A socket path containing a `:` is not addressable, the same limit an `ssh://` destination has.


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

A location written with a scheme — `ssh://` or `unix://` (§2) — is **remote by declaration**, and no address is consulted for it. Inference is what the form opts out of: a config alias can point anywhere, including back at this machine, and a unix socket or a `.host` name has no address to compare at all — there is nothing honest to guess with. Asking `ssh -G <destination>` what ssh itself resolved was the alternative considered; it was rejected as a process spawn and a second parser per remote side that still could not answer for the shapes that motivated the form. It also follows that reaching *this* machine through its own `ssh` is a thing a user can ask for, rather than something quietly turned back into an in-process run.

### 4.2 Remote agent
The channel is a bidirectional byte stream behind a `Channel` interface, and the same protocol runs over every transport. Two exist.

**Over ssh.**
- The same binary is installed on the remote host and started as `dsync agent --stdio` over `ssh`, by spawning the system `ssh` executable. That session serves exactly one replica and ends when its input closes.
- The destination is handed to `ssh` exactly as the location gave it and is never resolved, rewritten, or probed here. Whatever `ssh` accepts as its destination argument, dsync addresses.

**Over a socket.** `dsync agent --listen <socket path>` binds a unix socket and serves it, reached by a `unix://` location (§2). It is dsync's own transport: no system binary, which is what a head that cannot rely on one needs (§3, §16), and the read loop and buffering are this project's to tune rather than a borrowed library's.
- A listener outlives a session. It stays up, accepting until the process is signalled, and serves connections concurrently — one `AgentServer` per connection, which holds no state between them. Two sessions against the *same* replica are already handled by §4.3's lock; two against different replicas have nothing to contend over. A session that fails is reported and closed; it does not take the listener down, unlike `--stdio`, where the process *is* the session.
- The socket file is unlinked when the listener closes. One left behind by an agent that was killed outright is cleared on the next start, after connecting to it proves nothing is listening there.
- **It authenticates nobody.** `hello` names the root path and the agent is rooted wherever it says, which over ssh is harmless because the connection was already authenticated as that user. Here the only gate is the filesystem: on Linux, a connect is refused if the process cannot open the socket. That is why this transport is unix-domain and local by construction. A socket that leaves the machine needs authentication and encryption of its own, and does not have them yet (§16).
- Two things about a remote replica are configurable **per replica**, since SPEC §4.1 allows a pair of two remotes and two hosts need not agree on either: the **options** passed to `ssh` before the destination (`-p`, `-i`, `-o …`), and the **command** that starts the agent on the far side, which defaults to the bare word `dsync` resolved on the remote *non-interactive* PATH. Both come from the profile (§12) and the command line (§11.2). `~/.ssh/config` already answers port, identity, user and proxy command per destination and remains the better place for them; the options exist for what it cannot say, and for a one-off.
- Protocol: framed messages over the stream. Frame = 1 byte type + 4 byte big-endian length + payload. Type `0` = UTF-8 JSON control message, type `1` = raw file bytes, type `2` = a successful `scan` reply in the binary encoding of §15.3. A *failed* `scan` is a type `0` error like any other operation's, so the type byte is what distinguishes them. First exchange is a version handshake; mismatched protocol versions abort the run.
- Agent operations: `hello`, `lock`, `unlock`, `scan`, `readFile` (streamed), `writeFile` (streamed, temp + rename, set mtime/mode), `delete`, `removeEmptyDirs`, `archiveCommit`.
- `hello` carries the replica this connection should serve (root path — unexpanded — profile id, side, job count) and replies with that replica's archive last-commit time (or `null`), since the initiator cannot `stat` an archive on the remote host.

### 4.3 Locking
Each agent takes a lock file in its state directory for the replica before scanning and releases it at exit. A held lock aborts the run with a fatal error. This is what makes a listener (§4.2) safe to serve concurrently: two sessions reaching for the same replica meet the same lock a second `dsync` process would.

### 4.4 Pairing and the authenticated transport
Extends §4.2's socket transport past the local machine (task 4ec17f, under the pairing umbrella 589b90). §4.2's unix socket gets its access control from the filesystem for free; a socket that leaves the machine has to build its own, and the requirement is the same one stated there — an unpaired peer must not reach the version handshake, `hello`, or any frame parser, not be turned away by one.

**TLS with a self-signed certificate, via `dart:io`, not Noise.** `SecureServerSocket.bind(requireClientCertificate: true)` and `SecureSocket.connect(onBadCertificate:)` are the pinning hooks; the handshake itself runs in BoringSSL, inside the Dart VM, on every target platform (§3). The alternative was Noise (XX or KK, on `cryptography`'s X25519 keys and the Cacophony test vectors) — a genuine second option, not a formality, since `cryptography` ships X25519 where `pointycastle` only carries its OID, so taking route A did not mean dodging a hand-written elliptic curve. It was not taken because the two failure modes are not symmetric. A broken certificate encoder is loud: BoringSSL either completes a mutually-authenticated handshake with the bytes this project generated or refuses to load them, so a wrong `TBSCertificate` assembly cannot ship — it cannot connect to anything, including a second copy of itself. A subtly wrong Noise handshake state machine has no equivalent gate: two copies of the same bug still complete a handshake with each other, and the failure is silent and security-relevant rather than a thrown `HandshakeException`. Put the security protocol in BoringSSL, which the world already attacks; keep a data-format problem — the certificate encoder — for this project to own.

**The identity certificate.** `generateDeviceIdentity` (`lib/dsync_core/identity/self_signed_certificate.dart`) is what every peer generates once and keeps: an EC P-256 keypair (`ECCurve_prime256v1`), assembled into a version-3 X.509 certificate, self-signed with ECDSA-SHA-256 (issuer and subject are the same single-CN `RDNSequence` — the common name is cosmetic, since pairing pins the certificate's bytes, not its subject). Validity defaults to 3650 days and is backdated an hour from the moment of generation, so two clocks that disagree by a few minutes don't read a brand-new certificate as not-yet-valid. Two extensions, both marked critical: `basicConstraints` with `cA: TRUE`, and `keyUsage` with `digitalSignature | keyAgreement | keyCertSign`. The private key leaves the generator as PKCS#8, the spelling `SecurityContext.usePrivateKeyBytes` reads — SEC1's `EC PRIVATE KEY` is not accepted. None of this is negotiated per connection: there is exactly one shape, and the encoder that produces it — about 170 lines of code on `pointycastle` primitives, measured and spiked before being written for real — cannot produce any other.

**Why `cA: TRUE`.** This is the one requirement that isn't obvious from the TLS APIs alone. `SecureServerSocket`, unlike `SecureSocket.connect`, has no `onBadCertificate` hook — BoringSSL's own verification runs before any application code sees the connection, and a failure there kills the handshake before a paired peer could be recognized. Pinning a peer therefore has to happen by installing its certificate as a trust anchor, through `setTrustedCertificatesBytes` and `setClientAuthoritiesBytes`, and a self-signed *leaf* — `cA: FALSE` — cannot be its own issuer; BoringSSL refuses it with "unable to get local issuer certificate" before any pin is ever consulted. Making the identity certificate its own CA is what lets it stand in as a trust anchor at all. DER pinning — the exact-bytes comparison in `onBadCertificate`, and the equivalent check against `peerCertificate` on the server side — layers on top of that verification, never instead of it: a connection needs both a BoringSSL-valid chain (satisfied because the peer's certificate is its own trusted issuer) and an exact match against the specific DER a pairing recorded. A same-CN, different-key impostor certificate fails the second check even though it would pass the first.

**Device id: SHA-256 of the certificate's `SubjectPublicKeyInfo`, hex, grouped.** Syncthing's shape is a hash of the device certificate, rendered for humans; the deliberate choice here is *what* gets hashed. Hashing the whole certificate DER ties the id to the serial number and the validity window, both freshly generated if a certificate is ever renewed under the same key — which would silently change a device's id out from under an otherwise-unchanged pairing. Hashing only the `SubjectPublicKeyInfo` ties the id to the one thing that cannot change without it actually being a different device. It is rendered as lowercase hex in 4-character groups (`a1b2:c3d4:…`, sixteen groups from the 32-byte hash) — long enough to print in a paired-device list and in `dsync pair`'s output (task bc68c7), and grouped for the reason a hardware key fingerprint is: a human reading two of them side by side, or aloud, gets fixed points to check against instead of one 64-character run.

**The enrolment token, and what photographing the QR gets an attacker.** The QR carries three things: the desktop's certificate (or its DER — the trust anchor itself, and public by nature; there is nothing to protect by keeping it secret), an address hint, and a single-use, time-bounded enrolment token. The phone scans it, connects once, presents the token as proof it saw the QR, and registers its own certificate as a paired device; the token is burned on that first successful use, regardless of whose connection redeemed it. An attacker who photographs the QR — over a shoulder, from a recording — gets exactly the three things a legitimate phone would, and *can* complete enrolment in the phone's place, provided they get there first and inside the token's window. What bounds that: the window is short, the token is single-use (so the real phone and an attacker cannot both succeed — whichever arrives second fails, which is at least a visible signal rather than a silent compromise), and the desktop's enrolment endpoint is off by default and open only for the duration of one pairing operation — a photograph used outside that window, or reused after the token inside it is burned, gets nothing. This is a real cost against two-scan pairing, where the phone's identity also travels out of band and there is no token to steal at all; it is accepted because the same mechanism is what lets `dsync pair` (task bc68c7) work by exchanging text between two machines that both lack a camera, which two-scan pairing cannot do.

**Revocation is local, not a network operation.** `unpair` removes a device's certificate from the paired-device store (§8.3's state directory) on whichever side it is run on; that side stops installing the removed certificate as a trusted client authority or trust anchor, so the next connection attempt from it fails the same BoringSSL verification a stranger's would. No message is sent to the revoked device — sending one would mean trusting a channel to a peer this side has just decided not to trust, the same contradiction §4.2 and the pairing umbrella rule out for an unpaired peer generally. A device unpaired while it was offline therefore learns nothing at the moment of revocation; it finds out the next time it tries to connect, when the handshake fails exactly as it would for a device that was never paired — no distinct "you have been removed" error, because producing one needs the trust the revocation just withdrew. Unpairing is consequently one-sided by construction: running it on the desktop stops the desktop from trusting the phone, but the phone's own store still trusts the desktop until the phone — or someone with access to it — removes that entry too. A user who wants both directions severed runs it on both ends; nothing here does it for them.

## 5. Scan and change detection

Each agent scans its own replica and compares against **its own archive**. It returns a list of entries with a status relative to the archive, so the initiator never needs the full archive of the other side.

A path the scan cannot read — permission denied, or the entry vanished between the directory listing and the read — is **recorded and skipped, and the scan continues with the rest of the tree**, mirroring the per-path tolerance §7.6 gives the apply phase. One locked file does not cost the run. Such a path produces no status entry, for the same reason a skipped symlink does not (§5.1): a path the scan could not read has no state relative to the archive, so there is no cell of §6's table it belongs in. It is reported alongside skipped symlinks and contributes to the exit code (§11.5).

Archive entries beneath a directory whose listing failed are **not** reported `deleted`. The scan never got to look, so their absence from the walk is not evidence they are gone; reporting them would propagate a deletion the user never made to the other replica.

Silence is not enough on its own, though. An unreadable path is reported to reconciliation as well, and excluded there (§6) — because §6 reads a side's silence about a path as "this side has never seen it", which means *mirror it from the other side*. That is the right reading for a path that is genuinely absent and the wrong one for a path that is present and merely unread: it would overwrite a locally-edited file the scan could not look at, on a run that just said the path was not synced. An unreadable directory covers every path beneath it for this purpose, since the directory is what the scan reports but the files are what it hid.

The replica **root** is the exception: if the root itself cannot be listed, that is fatal (§11.5 exit 3), not a per-path skip. There is no tree left to sync, and reporting an empty one would invite mirroring the entire other replica into a directory this host cannot read.

### 5.1 What is scanned
- Regular files only. Directories are traversed but not tracked as entries.
- Symlinks: skipped and reported, unless the path matches a `follow` rule (§9), in which case the link is resolved and the target is treated as if it were at the link's path. A `follow` link that is broken, whose target is neither a regular file nor a directory, or that points back into a directory the walk is already inside, is also reported as skipped. Reported paths travel alongside the status list and surface as `symlink` lines (§11.4); they are not status entries, since a skipped link has no state relative to the archive to reconcile.
- Every reported path says *which* of those cases it was, not just that it was skipped. All four are one outcome to the tool — report it, plan nothing, leave the exit code alone — but not to the reader: a broken link and a link pointing back up its own tree need different fixes, and the walk is the only thing that ever knew which it saw.
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
dsync agent --listen <socket>     # bind a unix socket and serve it (§4.2)
dsync status <profile>            # scan + reconcile + print plan, apply nothing
```
`status` is `sync --dry-run` under a friendlier name.

`agent` needs exactly one transport, and neither is a default: they are not two spellings of the same thing — `--stdio` serves one session and ends with its input, `--listen` outlives any number of sessions — so a bare `dsync agent` is a usage error rather than a guess, and naming both is a usage error rather than a silent precedence rule. `--listen` ends on SIGINT or SIGTERM (§11.5's 130 / 143), which is what lets it unlink its socket on the way out.

### 11.2 Flags
```
--dry-run             show plan, apply nothing
--batch               apply non-conflicting actions without asking;
                      conflicts are listed, not resolved
--json                machine-readable output (JSON Lines) on stdout
--ignore <glob>       additive to profile
--warn-size <bytes>
--jobs <n>            hash parallelism
--ssh-option <arg>    one argv word for ssh itself, before the destination;
                      repeatable, additive to the profile
--remote-dsync <cmd>  the command that starts the agent on the far side
--verbose / --quiet
```
`--ssh-option` and `--remote-dsync` apply to every remote replica of the run *that is reached over ssh*. The value that reaches a replica is per replica (§4.2); a run whose two remotes need *different* values is what a profile's `[ssh.a]`/`[ssh.b]` is for. Neither has anything to say to a `unix://` replica — there is no argv to pass options to, and nothing to start on the far side, because the listener is already running — so a run that names both is not an error; they simply do not apply there.

### 11.3 Interactivity
Default is interactive: the plan is shown, conflicts first, then each proposed action; the user accepts, skips, or picks a direction per item, or accepts all remaining. `--batch` skips the prompts for non-conflicts. With `--batch`, conflicts are never resolved automatically.

### 11.4 Output
- Human mode: a run header naming both replicas and when the pair last synced, then a plan table, then progress lines during apply, then a summary (applied / skipped / conflicts / failed / unreadable). The header prints before anything moves, so a mistyped location is caught while it is still harmless; when either side has no archive it says so, because that run mirrors rather than propagating deletions (§6). `skipped` counts proposed actions the user declined; `unreadable` counts paths §5 could not read, which were never proposed at all — two different questions, so two different numbers.
- `--json`: one JSON object per line with a `type` field (`replicas`, `plan`, `action`, `conflict`, `symlink`, `unreadable`, `scanTally`, `progress`, `result`, `summary`, `error`). `symlink` reports a link the scan skipped (§5.1); `unreadable` reports a path it could not read (§5). Both carry a `detail`: which of §5.1's cases the link was, or the OS's own reason for the failed read. They are separate types rather than one type with a `reason` field, so a consumer already filtering for `symlink` — a thing that is normal on every run — does not silently start matching failures too. `scanTally` reports, per side, how many scanned paths resolved through each of §5.2's branches — most usefully `metadataMatched` against `hashMatched`, the fast path against the rehash it took to prove an unchanged file's drifted size or mtime meant nothing. `replicas` is the header's data — each side's location, locality, archive path and last-commit time, plus the profile id and `firstSync` — as facts only; the human warning is a rendering of `firstSync`, not a string on the wire. Human text goes to stderr in this mode so stdout stays parseable.

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

`dsync agent --listen` reports 130/143 too, although a signal is its
*ordinary* way out rather than an interruption: there is no input to close
and no run to have got partway through, and 128 + signal is what a shell
reports for a program that does not trap them at all. Trapping them buys the
socket being unlinked (§4.2), not a different code.

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

[ssh.b]
options = ["-i", "~/.ssh/id_phone"]
command = "/data/data/com.termux/files/usr/bin/dsync"
```
Command-line flags override profile options. `ignore` is additive, and so is `--ssh-option`, for the same reason: a profile's `-i` is what makes the connection work at all, and a `--ssh-option` typed once to debug a run must not silently drop it. Where the same ssh option is given twice, ssh's own precedence decides.

`[ssh.a]` and `[ssh.b]` are keyed by the replica side they configure (§4.2), both optional, as is either key within them. They are ignored for a side that runs in-process — a profile may carry one for a replica that is local on this machine and remote from the other end of the pair.

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
`RemoteAgent`), `Channel` (+ `AgentListener`, the far end of the socket
transport), `Scanner`, `Reconciler`, `Plan`, `Applier`, `ArchiveStore`,
`RuleSet`, and a `RunController` that drives a run and emits events the heads
render.

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
3. **Protocol encoding**: length-prefixed JSON frames, *except* a successful `scan` reply, which is a hand-rolled binary payload in its own frame type (§4.2). Settled with measurements rather than left as a default; MessagePack (`package:msgpack_dart`) was the alternative and was not taken.

   Measured on a 100k-entry `scan` result, two-level paths, a unique SHA-256 each:

   | encoding | wire bytes | decode | peak RSS |
   |---|---|---|---|
   | JSON | 17.2 MiB | 162 ms | 320 MiB |
   | binary | 7.2 MiB | 47 ms | 223 MiB |

   `scan` is the only message worth this: it returns the whole replica's listing in one frame, so its size is the size of the tree, while every other operation carries one path or nothing. Those stay JSON — a second encoding for them would be code to maintain in exchange for bytes nobody can measure.

   **Hand-rolled rather than MessagePack** because the win here is the layout, not the syntax. MessagePack would still hand back a boxed map per entry and would still spell the hash as text; it also adds a pinned dependency to every host (§3), which is a real cost for a format this project can write in 200 lines.

   **The hash travels as raw bytes but stays a hex `String` in the model.** Halving its wire size (64 characters → 32 bytes) is where most of the 10 MiB comes from. Holding those bytes in `ScanEntry`/`ArchiveEntry` instead was measured too and rejected: it would take a further ~30 ms off a remote scan while adding ~10 ms to *every* archive load, since §8.2's log stays hex so it stays inspectable. That is ~20 ms net on a 100k-file remote run and a small loss on a local one, in exchange for changing two models, the scanner, the reconciler and the archive store.

   Task 9551c4 recorded a 6× decode win for bytes-in-the-model. It did not reproduce: that measurement's hex-rebuilding decoder grew each hash through a `StringBuffer`, and filling a code-unit list for `String.fromCharCodes` recovers almost all of the difference without touching the model.
4. **Exit codes**: as in §11.5, mirroring Unison's four-level scheme.
5. **Profile format**: TOML.
6. **mtime comparison**: exact equality of microsecond values. If a target filesystem turns out to round mtimes, the archive stores the rounded value it reads back, so the next run's fast path still matches.
7. **Pairing handshake**: TLS with a self-signed certificate, not Noise (§4.4). Both were real options — `cryptography` ships X25519, so Noise would not have meant hand-writing an elliptic curve, which is the assumption that had wrongly ruled it out earlier. Taken on the failure mode instead: a broken certificate encoder cannot ship, because BoringSSL either completes a handshake with what it produced or refuses to load it, while a wrong Noise implementation still handshakes with itself and fails silently. The certificate is EC P-256 / ECDSA-SHA-256, hand-rolled on `pointycastle` rather than generated by `basic_utils` — about 170 lines this project owns, against a dependency that reaches the same PEM through `http`, `json_annotation`, `logging` and `archive` for one function's worth of use.

## 16. Deferred

- Flutter head beyond a skeleton that compiles against `core`.
- A transport that leaves the machine. §4.2's socket transport is unix-domain and local by construction, which is what lets the filesystem be its whole access control. The same `Channel` and the same listener over TCP is a small change; authentication and pairing are no longer open questions — §4.4 answers them — but they are not yet built: no `PairedDeviceStore`, no enrolment exchange, no TCP listener wired to the certificate machinery, no `dsync pair`. A Dart SSH client was considered for this and rejected: the transport is the hot path on a phone, and a borrowed implementation puts the read loop, the buffering and the framing inside a library this project cannot tune.
- Watch mode.
- Delta transfer (librsync via FFI or a Dart implementation).
- Negated ignore patterns.
- Ownership / xattr preservation.
- Case-insensitivity and Unicode-normalization handling beyond "whatever the filesystem does".
