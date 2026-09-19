import 'dart:convert';
import 'dart:io';

import 'package:dsync/dsync_core/lock/replica_lock.dart';
import 'package:dsync/dsync_core/state_dir.dart';
import 'package:test/test.dart';

void main() {
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('replica_lock_test');
  });

  tearDown(() async {
    await tempDir.delete(recursive: true);
  });

  File lockFile() => File('${tempDir.path}/replica.lock');

  group('acquire', () {
    test('creates the lock file and succeeds when nothing holds it', () async {
      final lock = ReplicaLock(lockFile());

      await lock.acquire();

      expect(await lockFile().exists(), isTrue);
      await lock.release();
    });

    test('throws when this process already holds the lock', () async {
      // The OS lock alone does not answer this: POSIX advisory locks are
      // owned by the process, so a second descriptor here is granted at
      // once. The Flutter head syncs in the same process as its UI, where
      // that would mean an archive deleted out from under its own run.
      final held = ReplicaLock(lockFile());
      await held.acquire();
      addTearDown(held.release);

      await expectLater(
        ReplicaLock(lockFile()).acquire(),
        throwsA(isA<ReplicaLockHeldException>()),
      );
    });

    test('holds against a second spelling of the same path', () async {
      final held = ReplicaLock(lockFile());
      await held.acquire();
      addTearDown(held.release);

      final sameFile = File('${tempDir.path}/./replica.lock');
      await expectLater(
        ReplicaLock(sameFile).acquire(),
        throwsA(isA<ReplicaLockHeldException>()),
      );
    });

    test('a release frees it for the next holder in this process', () async {
      final first = ReplicaLock(lockFile());
      await first.acquire();
      await first.release();

      final second = ReplicaLock(lockFile());
      await second.acquire();
      await second.release();
    });

    test('a refused acquire leaves the lock free for its holder', () async {
      final held = ReplicaLock(lockFile());
      await held.acquire();
      await expectLater(
        ReplicaLock(lockFile()).acquire(),
        throwsA(isA<ReplicaLockHeldException>()),
      );

      // The refused attempt did not claim anything: releasing the real
      // holder is still what frees the lock, and it is free afterwards.
      await held.release();
      final next = ReplicaLock(lockFile());
      await next.acquire();
      await next.release();
    });

    test('throws when another process already holds the lock', () async {
      final holderScript = File('${tempDir.path}/holder.dart');
      await holderScript.writeAsString('''
import 'dart:io';

void main(List<String> args) async {
  final handle = await File(args[0]).open(mode: FileMode.write);
  await handle.lock(FileLock.exclusive);
  stdout.writeln('locked');
  await stdin.first;
  await handle.unlock();
  await handle.close();
}
''');
      final holder = await Process.start('dart', [
        holderScript.path,
        lockFile().path,
      ]);
      final holderOutput = holder.stdout.transform(utf8.decoder);
      await holderOutput.firstWhere((line) => line.contains('locked'));

      final lock = ReplicaLock(lockFile());
      await expectLater(
        lock.acquire(),
        throwsA(isA<ReplicaLockHeldException>()),
      );

      holder.stdin.writeln();
      await holder.exitCode;

      // The holder released it, so the same lock file is now free.
      await lock.acquire();
      await lock.release();
    }, testOn: 'linux');
  });

  group('release', () {
    test(
      'allows a subsequent acquire on a fresh instance to succeed',
      () async {
        final first = ReplicaLock(lockFile());
        await first.acquire();
        await first.release();

        final second = ReplicaLock(lockFile());
        await second.acquire();
        await second.release();
      },
    );

    test('is a no-op when acquire was never called', () async {
      final lock = ReplicaLock(lockFile());
      await lock.release();
    });
  });

  group('resolveLockPath', () {
    test('uses XDG_STATE_HOME when set', () {
      final path = resolveLockPath(
        profileId: 'notes',
        side: 'a',
        environment: {'XDG_STATE_HOME': '/custom/state'},
        platform: const LinuxStateDir(),
      );
      expect(path.path, '/custom/state/dsync/notes-a.lock');
    });

    test('defaults to ~/.local/state when XDG_STATE_HOME is unset', () {
      final path = resolveLockPath(
        profileId: 'notes',
        side: 'b',
        environment: {'HOME': '/home/me'},
        platform: const LinuxStateDir(),
      );
      expect(path.path, '/home/me/.local/state/dsync/notes-b.lock');
    });
  });

  group('forProfile', () {
    test('resolves the standard path', () {
      final lock = ReplicaLock.forProfile(
        profileId: 'notes',
        side: 'a',
        environment: {'XDG_STATE_HOME': '/custom/state'},
        platform: const LinuxStateDir(),
      );
      expect(lock.path, '/custom/state/dsync/notes-a.lock');
    });
  });
}
