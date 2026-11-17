# Changelog

All notable changes to dsync are recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and dsync uses
[Semantic Versioning](https://semver.org/spec/v2.0.0.html); before 1.0.0 a
minor release may break compatibility between devices, and its notes say so.

## [Unreleased]

## [0.1.1] - 2026-11-17

### Added

The first release.

**Sync**

- Two-way sync of two replicas, one run at a time, reconciled against the
  stored state of the last run: nothing is overwritten or deleted unless the
  rules say it is safe or you confirm it.
- Profiles that hold several entries, each a folder or a single file, synced
  one after another; filters for what a profile leaves out.
- Review before applying: every planned action and conflict on its own row,
  answerable one by one, with reverse and keep-both choices and a side-by-side
  diff of a conflict or a planned copy.
- Guards that ask before a run deletes or overwrites most of a side, and a
  warning before a large transfer; the delete and transfer thresholds are
  settings.
- Crash-safe writes: every write lands in a temp, is hashed while streaming
  and renamed in only if it matches; an interrupted run is noticed and
  recovered on the next one.
- Paths that one side's filesystem cannot hold (case-folding collisions,
  names Windows refuses) are held back and reported, not mangled.
- A record of what each run did, and archive logs you can list and clear.

**Transports and pairing**

- Local paths, `ssh://` (and `user@host:path`) using the system ssh,
  `unix://` to a local `dsync agent --listen`, and `peer://` to a paired
  device over mutually authenticated TLS 1.3 pinned to its key.
- Pairing by QR code (shown in the terminal or the app) or a pasted line, with
  a device id to confirm on both sides; per-device grants of which folders it
  may reach; rename, re-address, renew and revoke.
- A dropped `peer://` run re-dials within a bounded window and keeps the
  review answers already given; a dead link is detected by heartbeat.

**CLI**

- `dsync sync`, `status`, `agent`, `pair` and `archive`, with `--dry-run`,
  `--batch`, `--json` (versioned JSON Lines), `--state-dir` and `--version`.
- `dsync agent --serve` under systemd, OpenRC or runit (examples in
  `contrib/`), with a documented process contract.
- A static CLI build for 64-bit ARM Linux, such as a Raspberry Pi.

**App (Android, Linux, macOS and Windows)**

- A home list of saved sync profiles, a run page that shows progress, counts
  and the review inline, and a dry run switch.
- Pairing in either direction, and a page that serves a replica to a paired
  device while it is open.
- On a desktop the app manages the same state as the CLI: this device,
  its pairings and what each may reach.
- On Android, a run keeps going with the screen off or the app in the
  background.
- Settings for theme, network bind address and port, keeping the screen
  awake, and the delete and transfer thresholds; Copy diagnostics for bug
  reports.
