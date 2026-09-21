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
/// **POSIX defaults for path style and `chmod`-availability, carried over
/// verbatim.** `ReplicaConnector` has always built its side `a` with
/// `LocalAgent`'s and `Scanner`'s POSIX defaults, on the reasoning that the
/// head shipped to Android and iOS only. That reasoning no longer holds —
/// `AppPaths.forHost` has five branches — and threading a real
/// `HostPlatform` through here is the fix, but it is a change with its own
/// blast radius through `Scanner` and `LocalAgent.isWindowsReplica` and it
/// is not this function's to make. What this function does guarantee is
/// that when the fix happens it happens once.
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
  return LocalAgent(
    rootPath: rootPath,
    readPool: ReadPool(),
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
