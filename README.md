# dsync

Bidirectional file sync between two replicas, one run at a time. Nothing is
overwritten or deleted unless the reconciliation rules say it is safe or the
user confirmed it; work is skipped whenever the stored state allows it.

See [SPEC.md](SPEC.md) for the v0 specification — it is the source of truth for
behaviour, and every module's doc comments reference its section numbers.

## Status

v0, in development. The core engine, the CLI and the Flutter head are
implemented; the head pairs by pasting the payload line or by scanning the QR
beside it (SPEC §4.4).

| Area | State |
|---|---|
| `lib/dsync_core/` — agent, scan, reconcile, apply, archive, protocol, rules | implemented |
| `lib/cli/` — args, profile, prompts, output | implemented |
| `lib/app/` — Flutter head: devices, pair, run setup, run | implemented |

## Using it

```sh
dsync sync <profile>              # the main one-shot run
dsync sync <locA> <locB>          # ad-hoc, no profile
dsync status <profile>            # scan + reconcile + print plan, apply nothing
dsync agent --stdio               # started by ssh on the remote host
dsync agent --listen <socket>     # bind a unix socket and serve it
dsync pair show                   # show this device's payload, wait for a peer
dsync pair accept <payload>       # pair with the device that payload came from
dsync pair list                   # paired devices; --json for a script
dsync pair grant <name> <path>    # let a paired device reach a replica root
dsync pair revoke <name>          # stop trusting it
```

A location is a local path, `user@host:path`, `ssh://[user@]destination:path`,
or `unix://<socket path>:<replica path>`; in an ad-hoc pair the local one comes
first. Either scheme is always remote, even when it leads back to this machine
(SPEC §4.1).

The `ssh://` form hands everything up to the first `:` to `ssh` as its
destination, unexamined — a `~/.ssh/config` alias,
`unix/run/ssh-unix-local/socket`, anything ssh accepts. `--ssh-option` passes an
argv word to ssh itself, and `--remote-dsync` names the command that starts the
agent on the far side when the bare `dsync` is not on its PATH.

The `unix://` form reaches a `dsync agent --listen` already bound to that
socket — dsync's own transport, with no system binary under it. It stays up
across sessions and ends on Ctrl-C, unlinking its socket. **It authenticates
nobody:** anyone who can open the socket can read, write and delete in the
replicas served through it, so keep it in a directory only you can enter, such
as `$XDG_RUNTIME_DIR`. That is why this transport is unix-domain and local
only; the one that leaves the machine is `dsync agent --serve` with a
`peer://` location on the other end, and it authenticates by pairing (below).

## Pairing

Two devices that have never met cannot talk. `dsync pair show` prints a payload
— this device's certificate, an address, and a single-use token good for five
minutes — and waits; `dsync pair accept <payload>` on the other device redeems
it. That payload is the trust anchor, so there is no "an unknown device wants
to connect, accept?" prompt anywhere: a device that was not paired out of band
is refused during the TLS handshake, before it reaches the version handshake,
`hello`, or any frame parser (SPEC §4.4).

Pairing a device and authorizing it are two steps. A freshly paired device is
trusted and can reach **nothing** until `dsync pair grant <name> <path>` says
which replica roots it may serve. `dsync pair revoke` takes it back, and takes
effect on the next connection attempt.

A paired peer is a replica location: `peer://<device-name>:<path>` (SPEC §2)
against a `dsync agent --serve` on that device. `dsync pair show` prints its
payload as a text line on stdout and, when the terminal can show one, as a QR
on stderr; the text is what a desktop-to-server pair exchanges (neither end
has a camera), and the Flutter head takes either form (below).

Profiles live in `$XDG_CONFIG_HOME/dsync/profiles/<name>.toml` (SPEC §12),
archives, locks, this device's identity and the paired-device set in
`$XDG_STATE_HOME/dsync/` (SPEC §8.3).

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
dart format --output=none --set-exit-if-changed lib test bin
dart analyze
dart test test/dsync_core test/cli   # core and CLI suites, no Flutter required
flutter test                         # everything, including test/app/
```

The core gate is scoped on purpose: a bare `dart test` compiles every file
under `test/`, and `test/app/` imports `package:flutter`, which cannot load
under plain `dart`. The guarantee it checks is unchanged — `dsync_core/` has
no Flutter dependency and its whole suite runs without one. For a fast loop
on one head file, `flutter test test/app/<file>.dart`.

### Running the head against a desktop

The app is a client of `dsync agent --serve` on a desktop; it cannot serve a
replica itself. From nothing to a first sync:

1. On the desktop, `dsync pair show`. It prints a `dsync-pair:v1:…` line and
   waits five minutes for the peer.
2. In the app, open **Pair a device** and either paste that line or tap
   **Scan the QR code with the camera** and point the phone at the code on the
   desktop's terminal. Name the desktop, then pair.
3. On the desktop, `dsync pair grant <app-name> <root>` for the folder the app
   may reach. Pairing and granting are two steps (SPEC §4.4): without this the
   run is refused, and the app cannot grant itself anything.
4. On the desktop, `dsync agent --serve`. It prints the address it serves on
   (port 28771 unless `--port` says otherwise).
5. In the app, tap the desktop, pick or create a local folder, type the
   granted root exactly as you granted it, and sync. A run applies by
   default; switch **Dry run** on to see the plan without applying.

The address the pairing cached is the port `dsync pair show` listened on, not
the agent's, so the first run against a fresh pairing needs the agent's
address typed into the address field on Run setup. A successful connect
records the new address and later runs use it.

**Android release builds reach the network.** `android/app/src/main/AndroidManifest.xml`
declares the `INTERNET` permission — Flutter provides it only to the `debug`
and `profile` source sets, so its absence there made every connect work under
`flutter run` and fail in a release build. The `CAMERA` permission the Pair
page's scanner reads through is declared there too, and `NSCameraUsageDescription`
is the iOS half of the same pair (SPEC §4.4).
