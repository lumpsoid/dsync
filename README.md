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
only; a socket that leaves the machine is deferred, along with the
authentication it would need (SPEC §16).

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

**Not yet reachable from a sync.** The transport and the pairing work, but
there is no way to *write down* a paired peer as a replica location yet — the
`peer://<device-name>:<path>` form SPEC §2 describes is not implemented. Until
it is, pairing sets up trust that only code can use. `dsync pair show` also
prints its payload as text rather than a QR, which is the primary path for a
desktop-to-server pair (neither end has a camera) but leaves phone-to-desktop
waiting on both the QR rendering and the Flutter head.

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
dart analyze
dart test            # core suite, no Flutter required
flutter test         # everything, including the Flutter head
```
