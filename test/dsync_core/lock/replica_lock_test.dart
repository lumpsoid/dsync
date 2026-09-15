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
