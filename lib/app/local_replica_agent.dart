import 'package:dsync/dsync_core/agent/local_agent.dart';
import 'package:dsync/dsync_core/agent/read_pool.dart';
import 'package:dsync/dsync_core/archive/jsonl_archive_store.dart';
import 'package:dsync/dsync_core/lock/replica_lock.dart';
import 'package:dsync/dsync_core/scan/case_folding.dart';
import 'package:dsync/dsync_core/scan/scanner.dart';

import 'app_paths.dart';

/// The one place the head builds a [LocalAgent] over a replica on *this*
/// device — the agent a run dials out with as its side `a`
/// (`ReplicaConnector`), and the agent the Serve page hands a paired peer
/// that dialled in (`ServeController`).
///
/// It exists because those two are the same object built from the same five
/// collaborators — the archive store, the replica lock, the scanner, the
/// archive log path and the case-folding probe — and every one of them is
/// keyed by the same `(profileId, side)` pair. Two copies of that wiring is
/// two places for an archive key to drift, and a drifted key is not a
/// crash: it is a first sync where there should have been a second one.
///
/// **Synchronous, and takes an already-resolved [paths].** The serving
/// side's `buildAgent` is `Agent Function(ReplicaSpec)` — no `await` is
/// available to it — so everything asynchronous is hoisted to whoever binds
/// the listener, which already holds `AppController.paths` resolved.
/// [detectsCaseFolding] is a synchronous filesystem probe and was already
/// called synchronously by both call sites before this existed, so nothing
/// was made harder to resolve by moving it here.
///
/// **Path style and `chmod`-availability come off [AppPaths.fileSystem],
/// not off the POSIX defaults.** `ReplicaConnector` built its side `a` with
/// `LocalAgent`'s and `Scanner`'s POSIX defaults for as long as the head
/// shipped to Android and iOS only; once `AppPaths.forHost` grew five
/// branches those defaults were wrong on exactly one of them — the Windows
/// head, which would have split and joined replica paths with `/` (SPEC §3)
/// and shelled out to a `chmod` that is not there (SPEC §7.4). Both this
/// head's agents are built here, so the host's answer is read here, once.
///
/// [rootPath] must already be expanded: a run's local root comes off the
/// Run setup page expanded, and a served root is expanded by the caller
/// against its own environment before it gets here — the same
/// `Location.expandedPath` call `lib/cli/commands/agent_command.dart`'s
/// `_buildAgent` makes, for the same reason.
LocalAgent buildLocalReplicaAgent({
  required AppPaths paths,
  required String rootPath,
  required String profileId,
  required String side,
  required int jobs,
}) {
  final platform = paths.stateDirPlatform;
  final fileSystem = paths.fileSystem;
  return LocalAgent(
    rootPath: rootPath,
    readPool: ReadPool(),
    pathStyle: fileSystem.pathStyle,
    isWindowsReplica: fileSystem.isWindowsReplica,
    archiveStore: JsonlArchiveStore.forProfile(
      profileId: profileId,
      side: side,
      rootPath: rootPath,
      platform: platform,
    ),
    replicaLock: ReplicaLock.forProfile(
      profileId: profileId,
      side: side,
      platform: platform,
    ),
    scanner: Scanner(
      jobs: jobs,
      pathStyle: fileSystem.pathStyle,
      // SPEC §16: this replica's own filesystem, probed once here — iOS's
      // default APFS volume folds case, Android's app storage does not, and
      // `detectsCaseFolding`'s own doc comment says why an OS check alone
      // would get a reformatted volume wrong.
      foldKey: caseFoldKeyFor(detectsCaseFolding(rootPath)),
    ),
    archivePath: resolveArchiveLogPath(
      profileId: profileId,
      side: side,
      platform: platform,
    ).path,
  );
}
