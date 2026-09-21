import 'dart:io';

import 'package:dsync/app/app_paths.dart';
import 'package:dsync/app/local_replica_agent.dart';
import 'package:dsync/dsync_core/archive/jsonl_archive_store.dart';
import 'package:dsync/dsync_core/host_file_system.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// What [buildLocalReplicaAgent] resolves, asserted as paths rather than as
/// behaviour.
///
/// The reason this file exists is narrow and worth stating: this function
/// was extracted out of `ReplicaConnector._localSide` so the Serve feature
/// could build the same agent, and the one way that extraction could go
/// wrong silently is by keying the archive or the lock differently. A
/// changed archive key is not a crash — it is a first sync where there
/// should have been a second one, on a replica the user already synced —
/// so the key is pinned here, against the same `AppPaths` a head resolves.
///
/// The host's filesystem answer (`AppPaths.fileSystem`) is pinned for the
/// same reason: it reached the agent as `LocalAgent`'s and `Scanner`'s POSIX
/// defaults for as long as the head shipped to Android and iOS only, which
/// on the Windows head means replica paths spelled with the wrong separator
/// (SPEC §3) and a `chmod` spawned that cannot exist (SPEC §7.4) — neither
/// of which fails at the call site that caused it.
void main() {
  late Directory tempDir;
  late AppPaths paths;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('local_replica_agent_test');
    paths = AppPaths(tempDir.path);
  });

  tearDown(() => tempDir.delete(recursive: true));

  test('the archive and the lock are keyed by profile id and side, in the '
      "head's own state directory (SPEC §8.1, §8.3)", () async {
    final root = await Directory('${tempDir.path}/notes').create();

    final agent = buildLocalReplicaAgent(
      paths: paths,
      rootPath: root.path,
      profileId: 'abc123',
      side: 'a',
      jobs: 2,
    );

    expect(agent.rootPath, root.path);
    expect(
      agent.archivePath,
      resolveArchiveLogPath(
        profileId: 'abc123',
        side: 'a',
        platform: paths.stateDirPlatform,
      ).path,
    );
    expect(agent.archivePath, startsWith(paths.stateDir));
    expect(agent.replicaLock.path, startsWith(paths.stateDir));
    expect(agent.replicaLock.path, contains('abc123'));
    expect(agent.replicaLock.path, endsWith('-a.lock'));
  });

  test('side b keys its own files, so a served replica never collides with '
      'a dialled one', () async {
    final root = await Directory('${tempDir.path}/notes').create();

    final a = buildLocalReplicaAgent(
      paths: paths,
      rootPath: root.path,
      profileId: 'abc123',
      side: 'a',
      jobs: 1,
    );
    final b = buildLocalReplicaAgent(
      paths: paths,
      rootPath: root.path,
      profileId: 'abc123',
      side: 'b',
      jobs: 1,
    );

    expect(a.archivePath, isNot(b.archivePath));
    expect(a.replicaLock.path, isNot(b.replicaLock.path));
    expect(b.replicaLock.path, endsWith('-b.lock'));
  });

  test("the agent reads the replica the way this head's own host spells it "
      '(SPEC §3, §7.4)', () async {
    final root = await Directory('${tempDir.path}/notes').create();

    final agent = buildLocalReplicaAgent(
      paths: paths,
      rootPath: root.path,
      profileId: 'abc123',
      side: 'a',
      jobs: 1,
    );

    // `paths` is the host-supplied (Android/iOS) branch, so POSIX — the
    // same value the defaults would have given, asserted so the Windows
    // case below is a real contrast rather than the only assertion.
    expect(paths.fileSystem, HostFileSystem.posix);
    expect(agent.pathStyle, p.Style.posix);
    expect(agent.scanner.pathStyle, p.Style.posix);
    expect(agent.chmodUnavailable, isFalse);
  });

  test('on the Windows head it spells them Windows-style and knows there is '
      'no chmod (SPEC §3, §7.4)', () async {
    final root = await Directory('${tempDir.path}/notes').create();
    final windows = AppPaths.forHost(
      'windows',
      environment: {'LOCALAPPDATA': tempDir.path, 'APPDATA': tempDir.path},
      supportDir: tempDir.path,
    );

    final agent = buildLocalReplicaAgent(
      paths: windows,
      rootPath: root.path,
      profileId: 'abc123',
      side: 'a',
      jobs: 1,
    );

    expect(agent.pathStyle, p.Style.windows);
    expect(agent.scanner.pathStyle, p.Style.windows);
    expect(agent.chmodUnavailable, isTrue);
  });
}
