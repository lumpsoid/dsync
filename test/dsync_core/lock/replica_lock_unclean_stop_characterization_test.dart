import 'dart:convert';
import 'dart:io';

import 'package:dsync/dsync_core/lock/replica_lock.dart';
import 'package:test/test.dart';

import '../../support/dsync_binary.dart';

/// Characterizes what a lock file left behind by a *killed* process does to
/// the next [ReplicaLock.acquire] — nothing at all — and why.
///
/// This is the path a supervisor exercises more than any other: a power cut,
/// an OOM kill, a `systemctl kill -s KILL`, and then a restart. A lock that
/// got this wrong would strand a server after an unclean stop, and would do
/// it invisibly — on the very next boot, on a machine nobody is watching.
///
/// **The reason it is already right is structural, and worth keeping.**
/// [ReplicaLock.acquire] does not write a PID file and does not read one.
/// It opens the path `FileMode.write` and takes a real kernel lock on the
/// open descriptor (`handle.lock(FileLock.exclusive)`). The kernel owns that
/// lock, so it drops it when the holding process dies — SIGKILL included,
/// with no chance for the process to run any cleanup. All that survives on
/// disk is an ordinary file, and `FileMode.write` truncates it on the way
/// past, so neither its presence nor its contents can be an obstacle.
///
/// So these tests are not hunting a bug; they pin the property. If someone
/// later "improves" the lock into something that writes a PID, reads it back
/// and refuses when it looks like a live holder, this file is what says no —
/// that change reintroduces exactly the stale-lock failure this design
/// already avoids.
///
/// The third test pins the half a reader is likeliest to misread:
/// `ReplicaLock`'s static `_heldInProcess` set. It is not persistent state
/// and it is not shared between processes — it exists only because POSIX
/// advisory locks are per-process and so cannot see a *second* holder inside
/// one process. A dead process's entries die with its heap; a fresh process
/// starts with an empty set regardless of what is on disk.
void main() {
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('replica_lock_unclean');
  });

  tearDown(() async {
    await tempDir.delete(recursive: true);
  });

  File lockFile() => File('${tempDir.path}/replica.lock');

  /// Spawns a child that takes the real [ReplicaLock] on [path] and then
  /// blocks forever, so the only way it ever lets go is by dying.
  Future<Process> startHolder(String path) async {
    final script = File('${tempDir.path}/holder.dart');
    await script.writeAsString('''
import 'dart:io';

import 'package:dsync/dsync_core/lock/replica_lock.dart';

Future<void> main(List<String> args) async {
  await ReplicaLock(File(args[0])).acquire();
  stdout.writeln('locked');
  // Waiting on stdin, which the parent never writes to. It has to be a real
  // event source — a bare unfinished `Completer` would not keep the VM
  // alive, and this holder would exit cleanly on its own, which is the one
  // thing this file must not let it do. The only way out is the signal.
  await stdin.first;
}
''');
    final holder = await Process.start(dartExecutable, [
      '--packages=${Directory.current.path}/.dart_tool/package_config.json',
      script.path,
      path,
    ]);
    addTearDown(() => holder.kill(ProcessSignal.sigkill));
    await holder.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .firstWhere((line) => line.contains('locked'));
    return holder;
  }

  group('after a holder is SIGKILLed', () {
    test('a fresh acquire on the same path succeeds', () async {
      final holder = await startHolder(lockFile().path);

      // While it lives, the kernel lock is what refuses us — this process's
      // own set has never seen this path.
      await expectLater(
        ReplicaLock(lockFile()).acquire(),
        throwsA(isA<ReplicaLockHeldException>()),
      );

      holder.kill(ProcessSignal.sigkill);
      // Awaiting the exit is what makes this deterministic rather than a
      // race: the lock is gone once the process is reaped, so no polling and
      // no sleep is needed.
      expect(await holder.exitCode, isNot(0));

      final next = ReplicaLock(lockFile());
      await next.acquire();
      await next.release();
    }, testOn: 'linux');

    test('the leftover file is still there and is not an obstacle', () async {
      final holder = await startHolder(lockFile().path);
      holder.kill(ProcessSignal.sigkill);
      await holder.exitCode;

      // The file outlives the process that locked it; only the kernel lock
      // was released.
      expect(await lockFile().exists(), isTrue);

      // Contents a PID-file design would choke on: a plausible-looking
      // record of a holder that is not coming back. `acquire` never reads
      // it, and `FileMode.write` truncates it on the way past.
      await lockFile().writeAsString('4194304\n');

      final next = ReplicaLock(lockFile());
      await next.acquire();
      expect(await lockFile().readAsString(), isEmpty);
      await next.release();
      expect(await lockFile().exists(), isTrue);
    }, testOn: 'linux');

    test('the in-process held set never saw the dead holder', () async {
      final holder = await startHolder(lockFile().path);
      holder.kill(ProcessSignal.sigkill);
      await holder.exitCode;

      // The child's acquire ran against the child's own static set, in the
      // child's heap, which is gone. Ours is untouched, so the first acquire
      // here is free...
      final mine = ReplicaLock(lockFile());
      await mine.acquire();
      addTearDown(mine.release);

      // ...and the set still does its own job, which is strictly about a
      // second holder inside *this* process.
      await expectLater(
        ReplicaLock(lockFile()).acquire(),
        throwsA(isA<ReplicaLockHeldException>()),
      );
    }, testOn: 'linux');
  });
}
