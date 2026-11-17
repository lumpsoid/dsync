# dsync

[![test](https://github.com/lumpsoid/dsync/actions/workflows/test.yml/badge.svg)](https://github.com/lumpsoid/dsync/actions/workflows/test.yml)
[![license: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

Two-way file sync between two folders, on two machines or one, one run at a
time. dsync never overwrites or deletes anything unless its reconciliation
rules say it is safe or you confirmed it, and it skips work whenever the state
from the last run allows. There is no server and no account: devices talk to
each other directly, over ssh or over TLS between devices you paired.

## Features

- **Safe two-way sync.** Each run compares both sides against the state of
  the last run, so it knows which side changed. Conflicts are shown, never
  silently resolved, and a run that would delete or overwrite a large share
  of a side asks first.
- **A CLI and an app.** The `dsync` command line runs on Linux, macOS and
  Windows; the Flutter app runs on Android, Linux, macOS and Windows.
- **Many ways to reach the other side:** a local path, `ssh://` (with `dsync`
  on the far host), a local `unix://` socket, or `peer://` to a paired device
  over mutually authenticated TLS.
- **Pairing by QR code or a pasted line,** with per-device grants of which
  folders a paired device may reach, and revocation.
- **Dry runs** that show the plan without applying it, saved sync profiles,
  and an archive log of every run.
- **Interrupted runs recover:** an app killed mid-sync picks the run up on
  its next start.

## Install

Download from the [latest release](https://github.com/lumpsoid/dsync/releases/latest):

| You want | File |
|---|---|
| the Android app | `dsync-X.Y.Z-android.apk` |
| the desktop app on Linux | `dsync-X.Y.Z-linux-x86_64.tar.gz` |
| the desktop app on macOS | `dsync-X.Y.Z-macos.zip` (unsigned: right-click → Open the first time) |
| the desktop app on Windows | `dsync-X.Y.Z-windows-x86_64.zip` |
| the CLI | `dsync-cli-X.Y.Z-<os>-<arch>.tar.gz` (`.zip` on Windows) |
| the CLI on a Raspberry Pi (64-bit OS) | `dsync-cli-X.Y.Z-linux-arm64.tar.gz`, statically linked |

Check the download against `SHA256SUMS` from the same release:

```sh
sha256sum -c SHA256SUMS --ignore-missing
```

The Android APK is signed by the dsync release key, whose certificate SHA-256
is

```
62:DC:20:1B:63:6E:07:3C:ED:AA:FB:21:26:3B:60:B5:EE:D7:B2:7A:A8:A7:29:9D:24:80:CD:18:CA:6D:8B:97
```

`apksigner verify --print-certs dsync-X.Y.Z-android.apk` prints it. On
Android the app asks for:

- **network**, to reach the devices you paired and nothing else;
- **camera**, only to scan a pairing QR code;
- **All files access**, so it can sync any folder you pick;
- **notifications and a foreground service**, to keep a running sync going
  with the screen off.

## Build from source

You need [rustup](https://rustup.rs) and Flutter 3.47.9.

```sh
git clone https://github.com/lumpsoid/dsync.git && cd dsync
(cd native && cargo install --path cli)   # the dsync CLI
flutter pub get
flutter build linux                       # or apk, macos, windows
```

[docs/development.md](docs/development.md) covers the Android NDK, the tests,
and the layout in detail.

## How it works

The engine is Rust, in a cargo workspace under `native/`: `dsync-domain` holds
the pure rules (reconcile, plan, exit policy) with no I/O at all, `dsync-core`
does the I/O (scanning, stores, the protocol, transports, pairing and the run
itself), and `dsync-cli` is the `dsync` binary over it. The Flutter app in
`lib/app/` talks to the same core through a small bridge crate, so the CLI and
the app run identical sync logic and share one state directory on a desktop.
[SPEC.md](SPEC.md) is the full specification.

## Using it

```sh
dsync sync <profile>              # the main one-shot run
dsync sync <locA> <locB>          # ad-hoc, no profile
dsync status <profile>            # scan + reconcile + print plan, apply nothing
dsync agent --stdio               # started by ssh on the remote host
dsync agent --listen <socket>     # bind a unix socket and serve it
dsync agent --serve               # serve paired devices over the network; --bind/--port to place it
dsync pair show --name <name>     # show this device's payload, wait for a peer, record it as <name>
dsync pair accept --name <name> <payload>  # pair with the device that payload came from, as <name>
dsync pair list                   # paired devices; --json for a script
dsync pair grant <name> <path>    # let a paired device reach a replica root
dsync pair address <name> <host[:port]>  # where to dial a moved paired device
dsync pair revoke <name>          # stop trusting it
dsync archive list                # the archive logs this host keeps
dsync agent --serve --state-dir <dir>      # keep this instance's state there, not the default
```

`--state-dir` overrides where this invocation keeps its state — archive logs
and their locks, this device's identity, the paired-device store — instead of
SPEC §8.3's platform default. It takes the path verbatim, and `agent` and
every `pair` and `archive` subcommand accept it. Two agents on one host need
one each; see "Running the agent under a service supervisor" below.

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

Two devices that have never met cannot talk. `dsync pair show --name <name>`
prints a payload — this device's certificate, an address, and a single-use
token good for five minutes — and waits; `dsync pair accept --name <name>
<payload>` on the other device redeems it. Each side names its peer, for
itself, and neither name travels: the device being enrolled has no say in what
it is stored as (SPEC §4.4), and that name is the handle `dsync pair grant`
and `peer://` address it by. That payload is the trust anchor, so there is no
"an unknown device wants to connect, accept?" prompt anywhere: a device that
was not paired out of band is refused during the TLS handshake, before it
reaches the version handshake, `hello`, or any frame parser (SPEC §4.4).

Pairing is two-sided, and the showing side gets the last word. Once a device
redeems the token, `dsync pair show` prints the device id derived from the
certificate it presented and asks — compare it against the id the other
device shows (`dsync pair accept` prints its own as it connects) and answer
`y` or `n`. Nothing is recorded until you do, so somebody who got hold of the
payload and redeemed it first is turned away rather than left in the store to
be noticed later. The token is spent either way: a refusal means showing a
fresh payload. Because there is a question to answer, `dsync pair show` needs
a terminal — it will not start without one, and a window nobody is at will
not complete on its own.

Pairing a device and authorizing it are two steps. A freshly paired device is
trusted and can reach **nothing** until `dsync pair grant <name> <path>` says
which replica roots it may serve. `dsync pair revoke` takes it back, and takes
effect on the next connection attempt.

A paired peer is a replica location: `peer://<device-name>:<path>` (SPEC §2)
against a `dsync agent --serve` on that device. `dsync pair show` prints its
payload as a text line on stdout and, when the terminal can show one, as a QR
on stderr; the text is what a desktop-to-server pair exchanges (neither end
has a camera), and the Flutter head takes either form (below). The head shows
the same payload itself, as a symbol and a copyable line, from **Pair a
device → Show this device's code** — for the pairing where the camera is on
the other device. It asks what to call the device about to be paired before it
shows anything, for the same reason `--name` is required on the CLI.

Profiles live in `$XDG_CONFIG_HOME/dsync/profiles/<name>.toml` (SPEC §12),
archives, locks, this device's identity, the paired-device set and the
Flutter head's own saved runs in `$XDG_STATE_HOME/dsync/` (SPEC §8.3) — the
head's saved runs are its own store, not §12's file, and re-run from its home
list, not from `dsync sync`.

Every run prints a header naming both replicas and when the pair last synced,
before anything moves. `--dry-run` and `status` show the plan and apply
nothing; `--batch` applies without prompting but never resolves a conflict;
`--json` writes JSON Lines to stdout. See SPEC §11.2 for the full flag list
and §11.5 for the exit codes.

SIGINT and SIGTERM stop any dsync process — a run, `dsync agent
--listen`/`--serve`, `dsync pair show` — and it exits 130 or 143 (SPEC §11.5).
**It exits within 10 seconds of the signal, whether or not its shutdown
finished**: the flush-then-release of §4.3 gets that long and no longer, so a
wedged socket or a peer that stopped answering costs a late exit rather than a
process that never leaves. Give a supervisor's kill timeout more than 10
seconds — systemd's `TimeoutStopSec=30s`, say — so dsync's own bounded exit
runs instead of a SIGKILL, which releases nothing.

## Exposing an agent beyond the LAN

`dsync agent --serve` binds every IPv4 interface by default — `--bind` defaults
to `0.0.0.0` — because the point of that transport is a peer on another host.
On a machine with a public address, that means the port (28771 unless `--port`
says otherwise) is open to the internet, and the thing standing in front of it
is the pinned mutual TLS handshake: a device that is not in `dsync pair list`
is refused during that handshake, before it reaches the version handshake,
`hello`, or any frame parser (SPEC §4.4).

**An HTTP reverse proxy cannot front it.** nginx `proxy_pass`, haproxy in
`mode http`, Caddy, Traefik — anything that terminates TLS breaks this
transport outright, and it will look like a certificate bug rather than a
configuration one. The authenticated fact is "the peer on *this socket*
presented key X", and terminating TLS destroys it: the proxy has no private
key to present onward on the client's behalf, and a header asserting the
device id is only the proxy's word for it (SPEC §4.4).

What does work is L4 passthrough, which terminates nothing:

```nginx
stream {
  server {
    listen 28771;
    proxy_pass 10.0.0.5:28771;
  }
}
```

haproxy's `mode tcp` is the same arrangement. That is also where per-source
rate limiting belongs. dsync bounds an unauthenticated connection with a
deadline and a counter rather than a rate limiter, deliberately: a rate limiter
needs a key, and per-IP is wrong behind NAT and wrong for an IPv6 /64 (SPEC
§4.4). The passthrough layer knows the address and the policy there is yours.

**Do not forward the pairing port.** `dsync pair show` binds a *separate*
listener, on an ephemeral port and — by default — on every IPv4 interface too,
and it exists only for the duration of that one pairing: it is off the rest of
the time. Forwarding the serve port alone leaves it unreachable from outside,
which is the arrangement you want. Pair over a LAN or a tunnel, or paste the
payload text between two terminals, and leave the enrolment endpoint off the
internet.

**The recommendation: put the serve port on an overlay network.** WireGuard,
Tailscale or Nebula cost this project no code and are your dependency rather
than dsync's (SPEC §16), and `--bind` is what attaches dsync to one:

```sh
dsync agent --serve --bind 10.8.0.3             # the tunnel's own address
dsync pair show --name laptop --bind 10.8.0.3
```

A non-wildcard `--bind` is also what `pair show` advertises in the payload, so
the peer dials the tunnel address with no `--advertise` needed (SPEC §11.1).
Bound there, the listener answers on that interface only, and the mutual TLS
is defence in depth rather than the only layer. A `--bind` that cannot be bound
is fatal and names the address it was given — there is no fallback to another
one, so a tunnel that is down shows up as an agent that did not start, not as
an agent quietly serving the internet.

SPEC §16 orders the reachability answers this project endorses — a direct route
first (IPv6, a LAN, a forwarded port), then your own overlay network. That
ordering is about what it takes to reach a host at all, not about how exposed
the result is: direct exposure is defensible, and the handshake is the gate it
claims to be, but on a public-facing host the overlay is the better default.

## Running the agent under a service supervisor

`dsync agent --serve` (or `--listen`) is meant to be run by systemd, OpenRC,
runit, s6 or launchd. dsync owns the *process contract*; whoever packages it
owns the glue. Example units for systemd, OpenRC and runit are in
[`contrib/`](contrib/) — community-maintained examples, not supported
integrations. What this project commits to is below, and it is what those
examples, and any others, are written against.

**It runs in the foreground and never daemonizes.** No fork, no PID file, no
detaching, no `--daemon`. The process you start is the process that serves,
and it is the process the supervisor tracks — `Type=simple`, runit's and s6's
only model, OpenRC without `--background`. This is the load-bearing one:
anything that backgrounded itself later would break every integration at once.

**It logs to stdout and stderr and manages no log files.** No rotation, no log
path setting, no syslog socket. journald, svlogd, s6-log and launchd all
capture the two streams they already have; a program writing its own log file
fights all four. (The run history in the state directory, `runs.jsonl`, is not a
log of the process: it is one record per sync run this host started, rotated
by size, and read with `dsync log` — SPEC §8.3.) Startup lines and errors go to stderr — a listener's stdout
carries nothing, and `--json` on the run commands keeps stdout parseable
(SPEC §11.4).

**SIGTERM is the stop signal.** SIGINT exits 130 and SIGTERM 143 (SPEC §11.5),
and shutdown releases the replica lock and unlinks a `--listen` socket on the
way out. **It exits within 10 seconds of the signal, whether or not that
shutdown finished** — `StopSequence` (`native/cli/src/stop.rs`) owns that
bound, and the paragraph above under "Pairing" says what it costs. Set a kill
timeout above it, not below: `TimeoutStopSec=30s` on systemd, and the
equivalent elsewhere. A SIGKILL is the one exit path that releases nothing.
Do not configure a supervisor to stop it with any other signal.

**It needs no root.** Run it as an unprivileged user that can read and write
the replica roots and the state directory, and nothing else. It binds 28771 by
default (`--port` to change it), which needs no privilege.

**A service starts with a nearly empty environment — no `HOME`, no
`XDG_STATE_HOME`, no D-Bus session — and that is fine.** The agent needs no
desktop session, no keyring, no display. What it reads from the environment,
and what each falls back to:

| Variable | Used for | If unset |
|---|---|---|
| `XDG_STATE_HOME` | state directory on Linux (SPEC §8.3) | `$HOME/.local/state` |
| `HOME` | the fallback above; macOS's state directory; expanding a `~` in a replica path | **fatal** if the state directory is not otherwise resolvable |
| `LOCALAPPDATA` | state directory on Windows (SPEC §8.3) | **fatal** on Windows |
| `TERM` | whether `pair show` can draw a QR — never read by `agent` | no QR, payload text only |

The fatal cases are deliberate: dsync says which variable is missing rather
than writing into a directory named `null`. **Set `--state-dir` and none of it
applies** — the flag names the state directory outright, so the unit is
self-describing and the agent does not care what the supervisor's environment
looks like:

```sh
dsync agent --serve --state-dir /var/lib/dsync
```

That is also what lets **two agents share a host**: give each its own
`--state-dir` and its own `--port`, and they have separate paired-device
stores, separate archive logs and separate locks (SPEC §8.3, §4.3). Without
it, both resolve the same directory and fight over it. Pair, grant and revoke
against a particular instance by passing that instance's `--state-dir` to the
`pair` subcommands too:

```sh
dsync pair show --name phone --state-dir /var/lib/dsync/media
dsync pair grant phone /srv/media --state-dir /var/lib/dsync/media
```

Pairing, granting and revoking take effect on the next connection, with no
restart (SPEC §4.4) — a supervisor never needs to reload the agent for them.

Deliberately not implemented, and named so neither reads as an oversight:
**`sd_notify` readiness**, because it is systemd-only and linking
`libsystemd` is exactly the coupling SPEC §16 is suspicious of (`Type=simple`
works today; if readiness is ever wanted, the protocol is one datagram to
`$NOTIFY_SOCKET`, plain enough to send from `std::net::UdpSocket` with no
library), and **socket activation** via a
pre-opened descriptor, where one `--listen-fd N` would cover systemd, launchd
and s6 at once. Both are noted in SPEC §16, waiting for somebody to ask.

## Known limits

What this version does not do, or cannot promise. Each entry points at the
SPEC section that owns the detail.

**Changes and what gets noticed**

- **An edit that keeps a file's size and modification time is not seen.** The
  scan trusts size and mtime before it hashes, so such a file reads as
  unchanged; touching it (a new mtime) makes the next run pick it up (SPEC
  §5.2).
- **A permissions-only change does not sync.** Mode bits travel with content,
  so a `chmod` alone reaches the other side the next time the file's content
  changes. Ownership and extended attributes (ACLs included) are never copied (SPEC
  §7.4).
- **A file edited while a run is applying is left alone, not synced.** It is
  reported "changed during sync" and picked up by the next run. The only
  uncovered moment is the instant between that check and the write (SPEC
  §7.6).
- **Nothing is kept of what a sync overwrites or deletes.** There is no trash
  and no version history; the guard that asks before a run deletes at least
  10 files and more than half of one side, and its sibling that asks before
  a run overwrites as many or empties 5 or more files, are the only brakes;
  `--allow-mass-delete` and `--allow-mass-overwrite` switch each off for
  that run (SPEC §10).
- **No watch mode and no delta transfer.** A sync happens when you start one,
  and a changed file is copied whole (SPEC §16).

**Names and file types**

- **Case and Unicode normalization are only partly handled.** On a
  case-insensitive replica (macOS, Windows), paths that already collide by
  case are reported and skipped, but two *new* files from the other side that
  differ only by case, or an NFC and an NFD spelling of one name, can land as
  one file. Avoid such pairs, or rename one before syncing (SPEC §5.1, §16).
- **Symlinks are never created.** A link is skipped unless a `follow` rule
  names it, and then its target's content is synced as a plain file at the
  link's path; the other side gets a file, not a link. The app offers no
  `follow` rules at all (SPEC §9). Fifos, sockets and device files are
  skipped too (SPEC §5.1).
- **Hardlinked names become separate files** on the other side (SPEC §5.1).
- **Ignore patterns cannot be negated** (SPEC §9, §16).

**Serving and pairing**

- **A paired device follows a symlink only into folders you granted it.**
  A run against your `dsync agent --serve` or the app's **Answer paired
  devices** page follows the links the *other* device's `follow` rules
  name, but only when the link's real target lies inside a folder granted
  to that device; any other link is skipped and reported, and reads and
  writes through it are refused. To sync a folder reached through a link,
  grant the target folder too — which also lets that device sync it
  directly (SPEC §4.4, §9).
- **The phone serves only while its page is open.** There is no background
  service, and the app always serves on port 28771 (SPEC §16).
- **A peer whose address changed has to be told again.** There is no
  discovery on the network: type the new address into Run setup, and a
  successful connect remembers it (SPEC §4.4, §16).
- **Two phones behind separate carrier NATs cannot reach each other.** One
  side needs a direct route or both need a shared overlay network such as
  WireGuard or Tailscale (SPEC §16).
- **Nested folders across different profiles are not locked out of each
  other.** A second run on a folder another run is syncing is refused
  because the folder is in use, whichever profile, entry or device started
  it; run it again when the first finishes. But `~/Docs` in one profile and
  `~/Docs/Photos` in another lock different folders, so both proceed.
  Nothing is corrupted: files the other run changes are skipped as changed
  during sync and the next run settles them, so start one at a time (SPEC
  §4.3, §16). Nesting *within* one profile's own entries is refused
  outright when the profile is loaded or saved, before either root is ever
  touched (SPEC §12).
- **A folder reached through a symlink is not locked.** The lock covers the
  folder a run names, not a granted folder a link inside it leads to, so a
  run on that folder directly and one through the link proceed together,
  with the same outcome as nested folders above (SPEC §4.4).

**Storage and versions**

- **Android folders with no filesystem path cannot be synced.** A folder the
  chooser turns into a path works, under All-files access; the Downloads
  provider or a cloud document provider does not (SPEC §16).
- **Files from a different major version are refused.** Archive logs,
  profiles, the paired-device store, pairing payloads and the wire protocol
  each carry their own `major.minor` format version; a dsync of another major
  says so and stops rather than guessing, so both devices need builds that
  agree on every major (SPEC §8.4). `dsync --version`, and the app's Settings
  page, name the build.

## The app with a desktop

The app pairs as a client of `dsync agent --serve` on a desktop; it can also
serve a replica of its own to another paired device, from its own **Answer
paired devices** page (SPEC §4.4, §16) — but that page has to be open in the
foreground for as long as the other side is connecting, since the app runs no
always-on agent in the background. From nothing to a first sync against a
desktop:

1. On the desktop, `dsync pair show --name <app-name>`, where `<app-name>` is
   what the desktop will call the app from then on — the name you will use in
   `dsync pair grant` below. It prints a `dsync-pair:1.0:…` line and waits five
   minutes for the peer. Add `--serve-port <port>` if this desktop's
   `dsync agent --serve` runs on anything but 28771: the payload tells the app
   where to reach it from then on, so this is the number the app stores and
   dials. Stay at that terminal: it asks you to confirm the app's device id
   before it records the pairing.
2. In the app, open **Pair a device** and tap **Scan QR code** — pointing the
   phone at the code on the desktop's terminal — or **Paste line** for the
   `dsync-pair:1.0:…` line. Either way the app then shows which desktop the
   code names and the address it will be reached at; check it, adjust the name
   the app will list the desktop under, and pair. There is no field for what
   the desktop calls the app: that is the `--name` given in step 1. The
   desktop then asks you to confirm the app's device id — **This device** in
   the app shows the same id to compare it against.
3. On the desktop, `dsync pair grant <app-name> <root>` for the folder the app
   may reach. Pairing and granting are two steps (SPEC §4.4): without this the
   run is refused, and the app cannot grant itself anything.
4. On the desktop, `dsync agent --serve`. It prints the address it serves on
   (port 28771 unless `--port` says otherwise).
5. In the app, tap the desktop, pick or create a local folder, type the
   granted root exactly as you granted it, and sync. A run applies by
   default; switch **Dry run** on to see the plan without applying.

The app's first page is the list of saved sync profiles, not the device list.
Name a run in Run setup's **Save as profile** field and it lands there; a tap
re-opens the form pre-filled — the same device, folder and root, the dry-run
switch back off — and Start re-runs it with no typing. A profile whose device
has been revoked, or whose local folder can no longer be read and written,
stays on the list rendered as broken and unrunnable rather than disappearing.

The address the pairing cached is the port `dsync pair show` listened on, not
the agent's, so the first run against a fresh pairing needs the agent's
address typed into the address field on Run setup. A successful connect
records the new address and later runs use it. For a paired device that has
moved, `dsync pair address <name> <host[:port]>` rewrites that address in the
store — or use the Device page in the app — with no re-pairing; every dial
reads the store, so the next run follows it.

## Contributing

Bug reports and ideas are welcome as
[issues](https://github.com/lumpsoid/dsync/issues). Please read
[CONTRIBUTING.md](CONTRIBUTING.md) before opening a pull request.

## License

MIT, see [LICENSE](LICENSE). The vendored `third_party/rinf` and its
`cargokit` keep their own licenses, in their directories.
