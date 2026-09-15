import 'dart:convert';
import 'dart:io';

import 'package:dsync/dsync_core/models/ssh_access.dart';
import 'package:dsync/dsync_core/protocol/ssh_channel.dart';
import 'package:test/test.dart';

void main() {
  group('sshArgsFor', () {
    test('inserts -T and the destination before the remote command', () {
      expect(sshArgsFor(host: 'example.com'), [
        '-T',
        'example.com',
        'dsync',
        'agent',
        '--stdio',
      ]);
    });

    test('prefixes the destination with user@ when a user is given', () {
      expect(sshArgsFor(host: 'example.com', user: 'me'), [
        '-T',
        'me@example.com',
        'dsync',
        'agent',
        '--stdio',
      ]);
    });

    test('places the access options before -T, where ssh reads its own', () {
      expect(
        sshArgsFor(
          host: 'example.com',
          access: const SshAccess(options: ['-p', '2222']),
        ),
        ['-p', '2222', '-T', 'example.com', 'dsync', 'agent', '--stdio'],
      );
    });

    test('puts the access command where the bare `dsync` goes', () {
      expect(
        sshArgsFor(
          host: 'example.com',
          access: const SshAccess(command: '/opt/bin/dsync'),
        ),
        ['-T', 'example.com', '/opt/bin/dsync', 'agent', '--stdio'],
      );
    });

    test('hands a destination with slashes in it to ssh unexamined', () {
      // A socket-activated sshd (SPEC §2, §4.2): nothing here may treat the
      // `/` as a path separator, or split, quote, or resolve any of it.
      expect(sshArgsFor(host: 'unix/run/ssh-unix-local/socket', user: 'me'), [
        '-T',
        'me@unix/run/ssh-unix-local/socket',
        'dsync',
        'agent',
        '--stdio',
      ]);
    });
  });

  group('connect', () {
    late Directory tempDir;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('ssh_channel_test');
    });

    tearDown(() async {
      await tempDir.delete(recursive: true);
    });

    /// A stand-in for `ssh`: reports the argv it was invoked with on
    /// stderr (so the test can assert on it without a real SSH connection),
    /// then echoes stdin back on stdout like the byte stream a real
    /// `dsync agent --stdio` would produce.
    Future<String> fakeSsh() async {
      final script = File('${tempDir.path}/fake-ssh');
      await script.writeAsString('''
#!/bin/sh
echo "args: \$*" 1>&2
exec cat
''');
      await Process.run('chmod', ['+x', script.path]);
      return script.path;
    }

    test(
      'spawns the executable with the ssh destination and remote command',
      () async {
        final channel = await SshChannel.connect(
          host: 'example.com',
          user: 'me',
          executable: await fakeSsh(),
        );

        final line = await channel.stderrLines.first;

        expect(line, 'args: -T me@example.com dsync agent --stdio');
        await channel.close();
      },
      testOn: 'linux',
    );

    test('spawns with the access options and remote command', () async {
      final channel = await SshChannel.connect(
        host: 'unix/run/ssh-unix-local/socket',
        user: 'me',
        access: const SshAccess(
          options: ['-i', '/keys/id_x'],
          command: 'XDG_STATE_HOME=/tmp/s /opt/bin/dsync',
        ),
        executable: await fakeSsh(),
      );

      final line = await channel.stderrLines.first;

      expect(
        line,
        'args: -i /keys/id_x -T me@unix/run/ssh-unix-local/socket '
        'XDG_STATE_HOME=/tmp/s /opt/bin/dsync agent --stdio',
      );
      await channel.close();
    }, testOn: 'linux');

    test('wraps child stdin/stdout as the Channel byte stream', () async {
      final channel = await SshChannel.connect(
        host: 'example.com',
        executable: await fakeSsh(),
      );

      await channel.send(utf8.encode('hello'));
      final chunk = await channel.input.first;

      expect(utf8.decode(chunk), 'hello');
      await channel.close();
    }, testOn: 'linux');

    test('stderr written before anyone listens is still available', () async {
      final script = File('${tempDir.path}/noisy-ssh');
      await script.writeAsString(
        '#!/bin/sh\necho "Permission denied (publickey)." 1>&2\nexec cat\n',
      );
      await Process.run('chmod', ['+x', script.path]);

      final channel = await SshChannel.connect(
        host: 'example.com',
        executable: script.path,
      );

      // Never subscribes to stderrLines: the line that explains a failed
      // connection arrives within milliseconds of the spawn, long before a
      // caller knows to ask, and a broadcast stream with no listener drops it.
      while (channel.recentStderr.isEmpty) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(channel.recentStderr, contains('Permission denied (publickey).'));

      await channel.close();
    }, testOn: 'linux');

    test('close kills a child that ignores the closed stdin', () async {
      final script = File('${tempDir.path}/wedged-ssh');
      // Never reads stdin and never exits — a wedged remote agent, or an ssh
      // session that will not give up the connection.
      await script.writeAsString('#!/bin/sh\nwhile true; do sleep 1; done\n');
      await Process.run('chmod', ['+x', script.path]);

      final channel = await SshChannel.connect(
        host: 'example.com',
        executable: script.path,
      );

      // Completes via the grace period and a signal rather than hanging the
      // run that is trying to finish.
      await expectLater(
        channel.close().timeout(const Duration(seconds: 30)),
        completes,
      );
    }, testOn: 'linux');
  });
}
