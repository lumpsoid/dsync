import 'dart:io';

import 'package:path/path.dart' as p;

/// Probes whether the filesystem actually mounted at [rootPath] folds case —
/// whether a path spelled with one case names the same file as the same path
/// spelled with another — by creating a marker file there and checking
/// whether it can also be read back under a different spelling of its own
/// name (SPEC §3, §16).
///
/// Deliberately **not** a property of `lib/cli/host_platform.dart`'s
/// `HostPlatform`, unlike every other per-host fact that file's
/// `hostPlatform` resolves — and so lives here, in core, next to its one
/// consumer (`Scanner.foldKey`) rather than in either head: SPEC §16 states
/// outright that this is "a property of the filesystem, not the OS" — a
/// case-sensitive-formatted APFS volume, or a case-insensitive mount on an
/// otherwise case-sensitive Linux host, each need the behaviour their
/// filesystem actually has, and a host-wide default would get both wrong. So
/// this asks the filesystem directly, the same way tools like git detect
/// `core.ignorecase`, rather than assuming an answer from the platform
/// underneath it. Both heads need the same answer for the same reason — the
/// Flutter head ships to iOS, whose default APFS volume folds — and one probe
/// shared is one rule, where a copy per head would be two that drift.
///
/// Synchronous, unlike [detectsCaseFolding]'s own doc comment might suggest
/// a probe needs to be: the three call sites that need this
/// (`lib/cli/agents/connected_replicas.dart`'s `_resolveLocalSide`,
/// `lib/cli/commands/agent_command.dart`'s `_buildAgent`, and
/// `lib/app/features/run/replica_connector.dart`'s `_localSide`) resolve
/// [rootPath] once per replica, at connect time, not once per file — and
/// `_buildAgent` is itself synchronous today (`Agent Function(ReplicaSpec)`,
/// shared by every transport `AgentServer`/`AgentListener` serve), so making
/// this asynchronous would mean threading `Future` through all of them for
/// one probe that already costs one file create, one stat and one delete,
/// once per run.
///
/// Best-effort: a [rootPath] this process cannot create a file in — not yet
/// created, no write permission, already gone — answers `false`, the
/// behaviour every filesystem this project can currently verify actually
/// has, rather than throwing a probe failure into a caller that only wanted
/// a yes/no. A replica whose root cannot be written at all fails loudly soon
/// enough regardless, once the scan or the first real write reaches it.
bool detectsCaseFolding(String rootPath) {
  final probeName =
      '.dsync-case-probe-${DateTime.now().microsecondsSinceEpoch}';
  final marker = File(p.join(rootPath, probeName));
  try {
    marker.createSync();
  } on FileSystemException {
    return false;
  }
  try {
    // Every letter in `probeName` is already lowercase, so uppercasing it
    // is guaranteed to spell a genuinely different path — not a case-fold
    // no-op — without needing a dedicated case-flipping helper.
    return File(p.join(rootPath, probeName.toUpperCase())).existsSync();
  } finally {
    try {
      marker.deleteSync();
    } on FileSystemException {
      // Best-effort cleanup: the probe's answer is already computed, and a
      // leftover dotfile is a smaller problem than losing that answer over
      // it.
    }
  }
}

/// The fold-key transform `Scanner` needs for SPEC §16's collision check,
/// derived from [detectsCaseFolding]'s already-resolved answer rather than
/// asking the filesystem a second time. `null` when [foldsCase] is `false`,
/// so a case-sensitive replica's scan skips the check machinery entirely
/// instead of computing a no-op key for every path it visits.
///
/// Lowercasing, specifically — not a second, independent policy — because
/// that is what "folds case" means for the one transform v1 implements.
/// `Scanner`'s own `foldKey` constructor parameter takes any
/// `String Function(String)`, not a `bool`, precisely so this is the only
/// place case-specific logic like `.toLowerCase()` has to live: SPEC §16
/// names Unicode normalization (NFC/NFD) as the same shape of problem,
/// expected to reuse `Scanner`'s same mechanism with a different transform
/// supplied here instead of a new one grown alongside it.
String Function(String path)? caseFoldKeyFor(bool foldsCase) =>
    foldsCase ? (path) => path.toLowerCase() : null;
