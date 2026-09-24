@Tags(['e2e'])
library;

import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:dsync/cli/dsync_cli.dart';
import 'package:dsync/cli/host_platform.dart';
import 'package:dsync/cli/options/cli_options.dart';
import 'package:dsync/cli/options/effective_options.dart';
import 'package:dsync/cli/options/sync_target.dart';
import 'package:dsync/cli/run/sync_runner.dart';
import 'package:dsync/dsync_core/archive/jsonl_archive_store.dart';
import 'package:dsync/dsync_core/models/archive.dart';
import 'package:dsync/dsync_core/models/ssh_access.dart';
import 'package:dsync/dsync_core/state_dir.dart';
import 'package:test/test.dart';

import '../../support/dsync_binary.dart';
import '../../support/real_ssh.dart';

/// task 185c8f: the interleaving nothing else in the suite reaches.
///
/// `reconciler_test.dart` covers every cell of SPEC §6's table on hand-built
/// status lists, `crash_safety_test.dart` kills an apply between the two
/// commits of SPEC §7.3, and the other tests in this directory each drive one
/// scripted run. What none of them do is *interleave*: a tree mutated several
/// ways at once, synced, mutated again, synced again, round after round, each
/// round starting from whatever state the last one actually converged on
/// rather than from a fixture. That is where a bug that survives a field test
/// lives.
///
/// One round is: stage random mutations across both replicas, sync once, and
/// assert three things —
///
/// - both replicas hold the same set of paths with the same contents;
/// - each replica's archive is an exact description of its *own* disk, so a
///   stale or missing entry is caught in the round that produced it rather
///   than three rounds later when it finally mis-resolves a path;
/// - the exit code is what the round's mutations imply (SPEC §11.5).
///
/// The same loop runs twice over: once against a local pair, and once against
/// a real `dsync agent --stdio` on the far end of a pipe (see
/// [_remoteSoakGroup]), because the two replicas' agent code paths differ and
/// the remote one is the less proven.
///
/// Decisions worth knowing before reading the generator:
///
/// - **The path pool is fixed and prefix-safe.** No path in [_pool] is an
///   ancestor directory of another, so a random round can never stage SPEC
///   §6's type-mismatch case — a file at `P` on one side, a directory at `P`
///   on the other — by accident. Round zero creates every one of them, split
///   across the two replicas, so the awkward names (spaces, unicode, a
///   leading dot, several levels deep, an empty file, a file over
///   `scanner.dart`'s 256 KiB isolate threshold) are in play from the start
///   instead of only when the dice say so.
/// - **Converged means files, not directories.** SPEC §5.1 scans files only,
///   and §7.5 has the applier remove just the directories *it* emptied — so
///   deleting a directory's last file on one replica leaves an empty
///   directory there and none on the other, forever, by design. Comparing
///   directories would fail correct behaviour.
/// - **Mode is never asserted.** SPEC §7.4: mode bits travel with content and
///   a mode-only difference is never detected or repaired, so an archive's
///   mode may legitimately disagree with the file it describes and the two
///   replicas' modes with each other. Nothing here chmods, and [_Facts] has
///   no mode field.
/// - **Conflicts are staged deliberately, then resolved.** A same-path edit on
///   both sides is a conflict by design (SPEC §6) and `--batch` never resolves
///   one (SPEC §11.3), so a round that stages one asserts exit 1 and that
///   *both* sides still hold exactly their own bytes — then resolves it the
///   way a user would, by picking replica `a`'s side by hand, and syncs again.
///   Without that second step one permanently conflicted path would drag
///   through every remaining round and the soak would stop testing anything.
/// - **The seed is random per run and printed on failure.** A soak that
///   replayed one fixed sequence forever would only ever test that sequence.
///   `DSYNC_SOAK_SEED` replays a red run exactly; `DSYNC_SOAK_ROUNDS` turns
///   the committed dozen rounds into a long soak by hand before a release.
///
/// One assumption, stated rather than worked around: the filesystem behind
/// `Directory.systemTemp` records mtimes finely enough that two writes to the
/// same path in different rounds get different ones. Every mainstream Linux
/// and macOS filesystem does. On a one-second-granularity filesystem SPEC
/// §5.2's fast path would legitimately miss a same-size rewrite, and this
/// would fail for that rather than for a bug.
Future<void> main() async {
  final rounds = _intFromEnvironment(_roundsVariable, 12);
  final seed = _intFromEnvironment(_seedVariable, Random().nextInt(1 << 32));

  group('convergence soak over $rounds rounds, local to local (SPEC §6, §7.3)', () {
    late Directory tempDir;
    late Directory rootA;
    late Directory rootB;
    late _Soak soak;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('dsync_soak_');
      rootA = await Directory('${tempDir.path}/replica-a').create();
      rootB = await Directory('${tempDir.path}/replica-b').create();
      final environment = {'XDG_STATE_HOME': '${tempDir.path}/state'};

      // The same derivation `SyncRunner.run` is about to do, with the same
      // inputs (SPEC §8.1, §8.3), so the two archive logs can be found by
      // name instead of by guessing at the hash in `adhoc-<16 hex>`.
      final target = AdHocTarget.parse(rootA.path, rootB.path);
      final effective = EffectiveOptions.forAdHoc(
        target,
        _batchOptions(target),
        environment: environment,
        workingDirectory: tempDir.path,
      );
      expect(
        effective.a.path,
        rootA.path,
        reason:
            'this test reads each side\'s archive by side letter, so it needs '
            'the ad-hoc ordering (SPEC §4.1: two local paths order '
            'lexicographically) to put "replica-a" on side a.',
      );

      soak = _Soak(
        random: Random(seed),
        a: _Replica(
          name: 'a',
          root: rootA,
          profileId: effective.profileId,
          archiveLog: resolveArchiveLogPath(
            profileId: effective.profileId,
            side: 'a',
            environment: environment,
            platform: const LinuxStateDir(),
          ),
        ),
        b: _Replica(
          name: 'b',
          root: rootB,
          profileId: effective.profileId,
          archiveLog: resolveArchiveLogPath(
            profileId: effective.profileId,
            side: 'b',
            environment: environment,
            platform: const LinuxStateDir(),
          ),
        ),
        sync: () => runDsyncCli(
          ['sync', rootA.path, rootB.path, '--batch', '--quiet'],
          environment: environment,
          workingDirectory: tempDir.path,
        ),
      );
    });

    tearDown(() async {
      await tempDir.delete(recursive: true);
    });

    test(
      'every round converges, and each archive describes its own disk',
      () async {
        printOnFailure(_reproduceHint(seed));
        await soak.run(rounds);
      },
      timeout: Timeout(Duration(seconds: 30 + 10 * rounds)),
    );
  });

  await _remoteSoakGroup(rounds: rounds, seed: seed);
}

/// The same soak against a real remote agent (SPEC §4.2) — task 185c8f: "the
/// agent code paths differ, and the remote one is the less proven of the two".
///
/// Every round here goes out over a pipe to a separate `dsync agent --stdio`
/// process and comes back framed, so the whole remote half — `RemoteAgent`,
/// the frame codec, `AgentServer`, the version handshake, a 256 KiB file
/// streamed over stdio rather than copied on one filesystem — is soaked as
/// hard as the local half, round after round.
///
/// By default the far side is reached through the `ssh` stand-in
/// `output_and_remote_e2e_test.dart` also uses: a script that ignores ssh's
/// arguments and execs this file's own compiled binary. Nothing about
/// convergence is specific to ssh being ssh — `real_ssh_e2e_test.dart` proves
/// that once, against a real sshd, and only a machine that has one can run
/// it. Gating a soak on that would leave the less proven code path soaked
/// nowhere, so this runs everywhere.
///
/// task 50de3d: setting `DSYNC_SSH_DESTINATION` ([RealSsh]) points the same
/// rounds at a real ssh session instead — every round then opens and tears
/// down a real connection, which is slower and is why it is not the default.
/// The two modes differ only in how the far side is reached; everything
/// below the transport is the same soak either way.
Future<void> _remoteSoakGroup({required int rounds, required int seed}) async {
  // Only when asked: a probe costs a connection attempt, and the default
  // suite has no reason to spend one.
  final probe = RealSsh.isConfigured ? await RealSsh.probe() : null;
  if (probe is SshUnavailable) {
    // Named, not silently ignored: a machine that asked for real ssh and
    // quietly got the stand-in would report a soak it did not run.
    throw StateError(
      '${RealSsh.destinationVariable} is set, but: ${probe.reason}',
    );
  }
  final ssh = probe as SshAvailable?;
  final transport = ssh == null
      ? 'an `ssh` stand-in'
      : 'real ssh to "${ssh.destination}"';

  // Not Windows: the stand-in is a `#!/bin/sh` script made executable by
  // `chmod`, and real ssh's far end is addressed with a POSIX `VAR=value`
  // prefix — see `real_ssh_e2e_test.dart`. The local soak above runs there.
  group('convergence soak over $rounds rounds, against a remote agent over '
      '$transport (SPEC §4.2)', () {
    late String binaryPath;

    setUpAll(() async {
      binaryPath = await dsyncTestBinary();
    });

    late Directory tempDir;
    late _Soak soak;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('dsync_soak_remote_');
      final localRoot = await Directory('${tempDir.path}/local').create();
      final remoteRoot = await Directory('${tempDir.path}/remote').create();
      final localEnvironment = {
        'XDG_STATE_HOME': '${tempDir.path}/local-state',
      };
      // The far side's own state directory. `SshChannel.connect` never
      // threads an environment to the process it spawns — on a real
      // connection the remote host's login environment fills that role — so
      // the stand-in exports it before exec'ing the agent (and the real-ssh
      // mode puts it in the remote command `--remote-dsync` names). Without
      // it the "remote" side would read and write this machine's real dsync
      // state.
      final remoteStateHome = '${tempDir.path}/remote-state';

      // The only difference between the two modes: which executable is
      // spawned, how the far side is addressed, and what runs over there.
      final String sshExecutable;
      final String remoteLocation;
      final List<String> sshOptions;
      final String remoteCommand;
      if (ssh == null) {
        final sshStandIn = File('${tempDir.path}/fake-ssh.sh');
        await sshStandIn.writeAsString(
          '#!/bin/sh\n'
          'export XDG_STATE_HOME="$remoteStateHome"\n'
          'exec "$binaryPath" agent --stdio\n',
        );
        await Process.run('chmod', ['+x', sshStandIn.path]);
        sshExecutable = sshStandIn.path;
        remoteLocation = 'me@fake-remote-host:${remoteRoot.path}';
        sshOptions = const [];
        remoteCommand = SshAccess.defaultCommand; // The stand-in ignores it.
      } else {
        sshExecutable = 'ssh';
        remoteLocation = ssh.locationFor(remoteRoot.path);
        sshOptions = ssh.options;
        remoteCommand = ssh.remoteCommandFor(
          binary: binaryPath,
          stateHome: remoteStateHome,
        );
      }

      final target = AdHocTarget.parse(localRoot.path, remoteLocation);
      final options = _batchOptions(
        target,
        sshOptions: sshOptions,
        remoteCommand: remoteCommand,
      );
      final effective = EffectiveOptions.forAdHoc(
        target,
        options,
        environment: localEnvironment,
        localAddresses: const {},
        workingDirectory: tempDir.path,
      );
      expect(
        effective.a.path,
        localRoot.path,
        reason: 'SPEC §4.1 puts the local side of a mixed pair first.',
      );

      soak = _Soak(
        random: Random(seed),
        a: _Replica(
          name: 'local',
          root: localRoot,
          profileId: effective.profileId,
          archiveLog: resolveArchiveLogPath(
            profileId: effective.profileId,
            side: 'a',
            environment: localEnvironment,
            platform: const LinuxStateDir(),
          ),
        ),
        b: _Replica(
          name: 'remote',
          root: remoteRoot,
          profileId: effective.profileId,
          archiveLog: resolveArchiveLogPath(
            profileId: effective.profileId,
            side: 'b',
            environment: {'XDG_STATE_HOME': remoteStateHome},
            platform: const LinuxStateDir(),
          ),
        ),
        // A fresh runner per round, so each round is its own session — which
        // is what a user gets, and what makes a session that fails to tear
        // down show up as the next round failing to connect.
        sync: () => SyncRunner(
          environment: localEnvironment,
          platform: const LinuxHost(),
          workingDirectory: tempDir.path,
          // No real lookup: the far side has to classify as remote (SPEC
          // §4.1) whatever this machine's interfaces say, or the run never
          // takes the agent path at all. The `ssh://` form says so itself;
          // `fake-remote-host` needs the empty set to say it.
          localAddressLookup: () async => const {},
          sshExecutable: sshExecutable,
        ).run(options),
      );
    });

    tearDown(() async {
      await tempDir.delete(recursive: true);
    });

    test('every round converges over the wire, and each archive describes its '
        'own disk', () async {
      printOnFailure(_reproduceHint(seed));
      await soak.run(rounds);
    }, timeout: Timeout(Duration(seconds: 120 + 20 * rounds)));
  }, testOn: '!windows');
}

/// `DSYNC_SOAK_ROUNDS`: how many rounds each soak runs. The committed default
/// is short enough for the normal suite; a long soak before a release is this
/// set to a few hundred.
const _roundsVariable = 'DSYNC_SOAK_ROUNDS';

/// `DSYNC_SOAK_SEED`: replays one exact sequence of mutations. Printed by
/// [_reproduceHint] whenever a soak fails.
const _seedVariable = 'DSYNC_SOAK_SEED';

String _reproduceHint(int seed) =>
    'seed $seed — replay this exact sequence with $_seedVariable=$seed';

/// The flags every soak run uses: apply everything non-conflicting without
/// asking (SPEC §11.3), and print nothing but the summary line, since a
/// couple of hundred rounds of plan tables is not output anyone reads.
CliOptions _batchOptions(
  SyncTarget target, {
  List<String> sshOptions = const [],
  String? remoteCommand,
}) => CliOptions(
  target: target,
  dryRun: false,
  batch: true,
  json: false,
  sshOptions: sshOptions,
  remoteCommand: remoteCommand,
  verbose: false,
  quiet: true,
  applyConcurrencyRaw: null,
);

/// Reads a positive-integer knob from the process environment.
///
/// A value that is not one fails the whole suite file at load: silently
/// falling back would have someone's `DSYNC_SOAK_ROUNDS=1OO` (with a letter
/// O) run twelve rounds and report a passing soak.
int _intFromEnvironment(String name, int fallback) {
  final raw = Platform.environment[name];
  if (raw == null || raw.isEmpty) return fallback;
  final value = int.tryParse(raw);
  if (value == null || value < 1) {
    throw ArgumentError.value(raw, name, 'must be a positive integer');
  }
  return value;
}

/// Files at least this large are hashed in their own isolate.
///
/// Mirrors `scanner.dart`'s own private threshold. A copy rather than an
/// export because the scanner's is an implementation detail of how it hashes,
/// not a contract — if it moves, this pool should keep crossing whatever the
/// new value is, and a soak that quietly stopped exercising the isolate
/// branch is exactly the kind of silent gap this file exists to close.
const _isolateThresholdBytes = 256 * 1024;

/// Every path the soak works with, with the size it is seeded at.
///
/// Fixed rather than generated, and prefix-safe: no path here is an ancestor
/// directory of another (see this file's doc comment). Between them they
/// cover what SPEC §5.1 has to walk past — a nested directory, a path several
/// levels deep, a directory whose only file can be deleted to empty it, names
/// with spaces, unicode, and a leading dot — plus an empty file and one over
/// [_isolateThresholdBytes].
const _pool = <_Candidate>[
  _Candidate('top.txt', 24),
  _Candidate('notes/a.txt', 400),
  _Candidate('notes/b.txt', 0),
  _Candidate('notes/deep/nested/further/c.txt', 1200),
  _Candidate('lonely/only-file.txt', 64),
  _Candidate('dir with spaces/file with spaces.txt', 33),
  _Candidate('ünïcødé/日本語のファイル.txt', 77),
  _Candidate('.dotfile', 12),
  _Candidate('hidden/.dotfile', 8),
  _Candidate('big.bin', _isolateThresholdBytes + 11),
  _Candidate('mixed/plain.txt', 51),
];

/// One entry of [_pool]: a path, and the size round zero creates it at.
class _Candidate {
  final String path;
  final int initialSize;

  const _Candidate(this.path, this.initialSize);
}

/// One replica as this test sees it: a root to mutate and walk, and the
/// archive log the run keeps for it (SPEC §8.3).
class _Replica {
  /// For failure messages — `a`/`b` locally, `local`/`remote` over ssh.
  final String name;

  final Directory root;
  final String profileId;
  final File archiveLog;

  _Replica({
    required this.name,
    required this.root,
    required this.profileId,
    required this.archiveLog,
  });

  File _file(String path) => File('${root.path}/$path');

  Future<bool> has(String path) => _file(path).exists();

  Future<List<int>> read(String path) => _file(path).readAsBytes();

  Future<void> remove(String path) => _file(path).delete();

  Future<void> write(String path, List<int> bytes) async {
    final file = _file(path);
    await file.parent.create(recursive: true);
    await file.writeAsBytes(bytes, flush: true);
  }

  /// Every file under [root], keyed by root-relative path. Directories are
  /// not reported, for the reason the file doc comment gives.
  Future<Map<String, _Facts>> files() async {
    final files = <String, _Facts>{};
    await for (final entity in root.list(recursive: true, followLinks: false)) {
      if (entity is! File) continue;
      final stat = await entity.stat();
      files[entity.path.substring(root.path.length + 1)] = _Facts(
        size: stat.size,
        mtime: stat.modified.microsecondsSinceEpoch,
        hash: _hash(await entity.readAsBytes()),
      );
    }
    return files;
  }

  /// This replica's archive, replayed through the real store (SPEC §8.2).
  ///
  /// The header handed to the store is the one this log is *supposed* to
  /// carry, so `load()`'s own check (SPEC §8.1) doubles as an assertion that
  /// this really is this root's archive rather than a leftover from another
  /// pair — over ssh, where the far end writes into the user's real state
  /// directory alongside every other profile, that is worth having.
  Future<Map<String, _Facts>> archived() async {
    final archive = await JsonlArchiveStore(
      archiveLog,
      ArchiveHeader(
        schemaVersion: JsonlArchiveStore.schemaVersion,
        profileId: profileId,
        rootPath: root.path,
      ),
    ).load();
    return {
      for (final entry in archive.entries.values)
        entry.path: _Facts(
          size: entry.size,
          mtime: entry.mtime,
          hash: entry.hash,
        ),
    };
  }
}

/// What every comparison in this file is made of: one file's size, mtime, and
/// content hash — the three fields an archive entry and a `stat` both carry.
///
/// No mode, deliberately: see this file's doc comment (SPEC §7.4).
class _Facts {
  final int size;
  final int mtime;
  final String hash;

  const _Facts({required this.size, required this.mtime, required this.hash});

  @override
  bool operator ==(Object other) =>
      other is _Facts &&
      other.size == size &&
      other.mtime == mtime &&
      other.hash == hash;

  @override
  int get hashCode => Object.hash(size, mtime, hash);

  @override
  String toString() => '$size B, mtime $mtime, sha256 ${hash.substring(0, 12)}';
}

/// How a staged conflict is shaped (SPEC §6's table: every one of these is a
/// cell that cannot be auto-resolved).
enum _ConflictKind {
  /// Both replicas edit an existing path to different content.
  bothEdit,

  /// Both replicas create the same new path with different content.
  bothCreate,

  /// One replica edits a path the other deletes.
  editVersusDelete,
}

/// One staged conflict: the path, what each replica is expected to still hold
/// once the run has refused to resolve it (`null` for the side that deleted
/// it), and a line for the failure log.
class _Conflict {
  final String path;
  final List<int>? onA;
  final List<int>? onB;
  final String description;

  const _Conflict({
    required this.path,
    required this.onA,
    required this.onB,
    required this.description,
  });

  /// SPEC §6: "Conflicts are never auto-resolved". Neither side's bytes may
  /// have moved — this is the assertion that tells a conflict apart from a
  /// run that silently picked a winner and still happened to exit 1.
  Future<void> expectUntouched(_Replica a, _Replica b) async {
    await _expectHolds(a, onA);
    await _expectHolds(b, onB);
  }

  Future<void> _expectHolds(_Replica replica, List<int>? expected) async {
    final present = await replica.has(path);
    if (expected == null) {
      expect(
        present,
        isFalse,
        reason:
            'replica ${replica.name} deleted $path, and an unresolved '
            'conflict must not bring it back.',
      );
      return;
    }
    expect(
      present,
      isTrue,
      reason:
          'an unresolved conflict must leave $path on replica '
          '${replica.name} alone, not delete it.',
    );
    expect(
      _hash(await replica.read(path)),
      _hash(expected),
      reason:
          'an unresolved conflict must leave $path exactly as replica '
          '${replica.name} wrote it.',
    );
  }

  /// What a user does when the tool hands them a conflict: pick a side. This
  /// always picks replica `a`'s and mirrors it onto `b` by hand — the one
  /// resolution `--batch` never performs itself (SPEC §11.3).
  ///
  /// The next run then finds the same hash on both sides, or the path gone
  /// from both, which SPEC §6 resolves as a commit-only: no bytes move, both
  /// archives come up to date, and the pair is converged again — so the soak
  /// carries on from a clean state instead of dragging one permanently
  /// conflicted path through every remaining round.
  Future<void> resolve(_Replica a, _Replica b) async {
    if (await a.has(path)) {
      await b.write(path, await a.read(path));
    } else if (await b.has(path)) {
      await b.remove(path);
    }
  }
}

/// The round loop: stage, sync, assert, repeat.
///
/// Concrete and single-implementation, like the ordering owners in `lib/`:
/// it holds the order the three steps happen in and the state they share
/// (the seeded [Random], the two replicas, and how to run one sync), while
/// every rule it asserts lives in SPEC and every value it compares is a plain
/// [_Facts].
///
/// [sync] is a callback rather than an interface for the same reason
/// `RunSync` in `lib/cli/run/sync_runner.dart` is one: the local soak runs
/// `runDsyncCli` over argv, the remote one runs a `SyncRunner` it has to
/// configure with an `ssh` stand-in, and the loop cares about neither — only
/// about the exit code it gets back (SPEC §11.5).
class _Soak {
  final Random random;
  final _Replica a;
  final _Replica b;
  final Future<int> Function() sync;

  _Soak({
    required this.random,
    required this.a,
    required this.b,
    required this.sync,
  });

  Future<void> run(int rounds) async {
    await _seed();
    for (var round = 1; round <= rounds; round++) {
      await _round(round);
    }
  }

  /// Round zero: every path in [_pool], split across the two replicas, so the
  /// first sync is a real two-way mirror and every later round has all of
  /// SPEC §5.1's awkward names to draw from.
  Future<void> _seed() async {
    final staged = <String>[];
    for (var i = 0; i < _pool.length; i++) {
      final candidate = _pool[i];
      final replica = i.isEven ? a : b;
      await replica.write(candidate.path, _bytes(candidate.initialSize));
      staged.add(
        '${candidate.path} (${candidate.initialSize} B) on '
        '${replica.name}',
      );
    }
    printOnFailure('round 0 created ${staged.join(', ')}');

    expect(
      await sync(),
      0,
      reason:
          'the first sync of the pair mirrors every seeded path in whichever '
          'direction has it and conflicts on none of them (SPEC §6, §11.5).',
    );
    await _expectConverged();
  }

  Future<void> _round(int round) async {
    final conflict = await _stageConflict();
    final mutations = await _stageMutations(exclude: conflict?.path);
    printOnFailure(
      'round $round: ${[...mutations, if (conflict != null) conflict.description].join('; ')}',
    );

    final exitCode = await sync();
    if (conflict == null) {
      expect(
        exitCode,
        0,
        reason:
            'a round that touches each path on at most one replica plans '
            'only copies and deletions, all of which --batch applies (SPEC '
            '§11.5: exit 0 is "all planned actions applied, no conflicts").',
      );
      await _expectConverged();
      return;
    }

    expect(
      exitCode,
      1,
      reason:
          'SPEC §11.5: a run that completed with an unresolved conflict exits '
          '1. ${conflict.description}',
    );
    await conflict.expectUntouched(a, b);
    // Everything else in the round still had to converge: one conflict must
    // not hold up the paths around it.
    await _expectConverged(exempt: {conflict.path});

    await conflict.resolve(a, b);
    expect(
      await sync(),
      0,
      reason:
          'once both replicas hold the same content for ${conflict.path}, '
          'SPEC §6 resolves it as a commit-only and the run is clean again.',
    );
    await _expectConverged();
  }

  /// Applies one to four mutations, each to a different path and each on one
  /// replica only.
  ///
  /// Different paths, because two replicas editing the same path in one round
  /// is the conflict case, which [_stageConflict] stages deliberately instead
  /// of leaving to chance — a soak that conflicted at random would spend most
  /// of its rounds asserting the same thing.
  Future<List<String>> _stageMutations({String? exclude}) async {
    // The replicas converged at the end of the last round, so either one's
    // file set answers "does this path exist" for both.
    final present = (await a.files()).keys.toSet();
    final paths = [
      for (final candidate in _pool)
        if (candidate.path != exclude) candidate.path,
    ]..shuffle(random);

    final staged = <String>[];
    for (final path in paths.take(1 + random.nextInt(4))) {
      staged.add(
        await _mutate(
          random.nextBool() ? a : b,
          path,
          exists: present.contains(path),
        ),
      );
    }
    return staged;
  }

  Future<String> _mutate(
    _Replica replica,
    String path, {
    required bool exists,
  }) async {
    if (!exists) return _write(replica, path, _randomSize(), 'created');

    final current = await replica.read(path);
    switch (random.nextInt(4)) {
      case 0:
        await replica.remove(path);
        return 'deleted $path on ${replica.name}';
      case 1 when current.isNotEmpty:
        // Same size, different bytes: the change SPEC §5.2's fast path can
        // only tell from the mtime.
        return _write(replica, path, current.length, 'rewrote in place');
      default:
        // A different size, which the fast path resolves without the mtime.
        // Also where an empty file's same-size rewrite lands: there is only
        // one file of length zero.
        var size = _randomSize();
        if (size == current.length) size++;
        return _write(replica, path, size, 'resized');
    }
  }

  Future<String> _write(
    _Replica replica,
    String path,
    int size,
    String verb,
  ) async {
    await replica.write(path, _bytes(size));
    return '$verb $path ($size B) on ${replica.name}';
  }

  /// One round in four, stages a same-path collision on both replicas; the
  /// other three rounds return `null`.
  ///
  /// Which kinds are available depends on the tree: two of the three need a
  /// path that already exists, the third needs one that does not. Every path
  /// is one or the other, so there is always at least one kind to pick from.
  Future<_Conflict?> _stageConflict() async {
    if (random.nextInt(4) != 0) return null;

    final present = (await a.files()).keys.toSet();
    // Both lists are in a fixed order — `_pool`'s, or sorted — so the same
    // seed picks the same path on any machine. A directory listing's order is
    // the filesystem's business, not this test's.
    final shared = present.toList()..sort();
    final absent = [
      for (final candidate in _pool)
        if (!present.contains(candidate.path)) candidate.path,
    ];

    final kinds = [
      if (shared.isNotEmpty) ...[
        _ConflictKind.bothEdit,
        _ConflictKind.editVersusDelete,
      ],
      if (absent.isNotEmpty) _ConflictKind.bothCreate,
    ];

    switch (kinds[random.nextInt(kinds.length)]) {
      case _ConflictKind.bothCreate:
        final path = absent[random.nextInt(absent.length)];
        final onA = _bytesUnlike(const {});
        final onB = _bytesUnlike({onA.length});
        await a.write(path, onA);
        await b.write(path, onB);
        return _Conflict(
          path: path,
          onA: onA,
          onB: onB,
          description:
              'conflict: both replicas created $path, ${onA.length} B on '
              '${a.name} and ${onB.length} B on ${b.name}',
        );

      case _ConflictKind.bothEdit:
        final path = shared[random.nextInt(shared.length)];
        final current = (await a.read(path)).length;
        final onA = _bytesUnlike({current});
        final onB = _bytesUnlike({current, onA.length});
        await a.write(path, onA);
        await b.write(path, onB);
        return _Conflict(
          path: path,
          onA: onA,
          onB: onB,
          description:
              'conflict: both replicas edited $path, to ${onA.length} B on '
              '${a.name} and ${onB.length} B on ${b.name}',
        );

      case _ConflictKind.editVersusDelete:
        final path = shared[random.nextInt(shared.length)];
        final deleteOnA = random.nextBool();
        final editor = deleteOnA ? b : a;
        final deleter = deleteOnA ? a : b;
        final edited = _bytesUnlike({(await editor.read(path)).length});
        await editor.write(path, edited);
        await deleter.remove(path);
        return _Conflict(
          path: path,
          onA: deleteOnA ? null : edited,
          onB: deleteOnA ? edited : null,
          description:
              'conflict: ${editor.name} edited $path to ${edited.length} B '
              'while ${deleter.name} deleted it',
        );
    }
  }

  /// The three convergence assertions, run at the end of every round.
  ///
  /// [exempt] is the path of an unresolved conflict, which by definition has
  /// not converged and whose archive entries are legitimately stale on both
  /// sides — the run refused to touch it, so nothing committed for it.
  Future<void> _expectConverged({Set<String> exempt = const {}}) async {
    final filesA = await a.files();
    final filesB = await b.files();
    for (final path in exempt) {
      filesA.remove(path);
      filesB.remove(path);
    }

    expect(
      _contentsOf(filesB),
      _contentsOf(filesA),
      reason:
          'the two replicas hold different files after this round; a sync '
          'that reported success should have left them with one set of paths '
          'and identical contents (SPEC §6).',
    );

    await _expectArchiveDescribesDisk(a, filesA, exempt);
    await _expectArchiveDescribesDisk(b, filesB, exempt);
  }

  /// SPEC §7.3: both sides commit each path as its action succeeds, so once a
  /// round is over each archive is an exact description of its own replica's
  /// disk — nothing missing, nothing stale, nothing left describing a file
  /// that is gone.
  ///
  /// Checked every round rather than once at the end because a wrong entry is
  /// invisible until some later round's fast path (SPEC §5.2) reads it and
  /// mis-resolves a path; checking here names the round that wrote it.
  Future<void> _expectArchiveDescribesDisk(
    _Replica replica,
    Map<String, _Facts> files,
    Set<String> exempt,
  ) async {
    final archived = await replica.archived();
    archived.removeWhere((path, _) => exempt.contains(path));
    expect(
      archived,
      files,
      reason:
          'replica ${replica.name}\'s archive no longer describes its own '
          'disk. An entry that is missing makes the next scan report the path '
          'as created; one left stale makes it report a change that already '
          'synced (SPEC §5.2, §7.3).',
    );
  }

  /// A size for the next write: usually small, sometimes empty, and one draw
  /// in six over [_isolateThresholdBytes] so the scanner's isolate branch is
  /// exercised repeatedly rather than once in a fixture.
  int _randomSize() {
    if (random.nextInt(8) == 0) return 0;
    if (random.nextInt(6) == 0) {
      return _isolateThresholdBytes + random.nextInt(2048);
    }
    return random.nextInt(4096);
  }

  /// Random content whose length avoids every length in [lengths].
  ///
  /// Length is the cheap way to guarantee a different hash, and a staged
  /// conflict needs one on both sides: SPEC §6 resolves same-hash edits as a
  /// commit-only rather than a conflict, and content identical to what the
  /// file already held is not an edit at all — the scan reports it unchanged.
  List<int> _bytesUnlike(Set<int> lengths) {
    var size = _randomSize();
    while (lengths.contains(size)) {
      size++;
    }
    return _bytes(size);
  }

  List<int> _bytes(int size) =>
      List<int>.generate(size, (_) => random.nextInt(256));
}

Map<String, String> _contentsOf(Map<String, _Facts> files) => {
  for (final entry in files.entries) entry.key: entry.value.hash,
};

/// Hashes the same way the scanner does (`scanner.dart`), so a mismatch here
/// is a mismatch there.
String _hash(List<int> bytes) => sha256.convert(bytes).toString();
