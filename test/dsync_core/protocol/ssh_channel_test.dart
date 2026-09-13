import 'dart:convert';
import 'dart:io';

import 'package:dsync/dsync_core/protocol/ssh_channel.dart';
import 'package:flutter_test/flutter_test.dart';

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

    test('places extraArgs before -T so they read as ssh options', () {
      expect(sshArgsFor(host: 'example.com', extraArgs: ['-p', '2222']), [
        '-p',
        '2222',
        '-T',
        'example.com',
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
  });
}
