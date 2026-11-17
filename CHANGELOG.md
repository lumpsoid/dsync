# Changelog

All notable changes to dsync are recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and dsync uses
[Semantic Versioning](https://semver.org/spec/v2.0.0.html); before 1.0.0 a
minor release may break compatibility between devices, and its notes say so.

## [Unreleased]

### Added

- Bidirectional sync of two replicas, one run at a time, with three-way
  reconciliation against the stored state of the last run; nothing is
  overwritten or deleted unless the rules say it is safe or you confirm it.
- The `dsync` CLI: `sync`, `status` (plan without applying), `agent`, `pair`
  and `archive`.
- Transports: local paths, `ssh://` (and `user@host:path`), `unix://` to a
  local agent, and `peer://` to a paired device over mutually authenticated
  TLS.
- Pairing by QR code or a pasted line, per-device grants of replica roots,
  and revocation.
- The Flutter app for Android, Linux, macOS and Windows: saved sync
  profiles, a dry run that shows the plan without applying, pairing, and serving a
  replica to a paired device while its page is open.
- Archive logs of every run, and recovery of a run interrupted mid-apply.
