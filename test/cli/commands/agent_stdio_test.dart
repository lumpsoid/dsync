@TestOn('linux')
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dsync/dsync_core/archive/jsonl_archive_store.dart';
import 'package:dsync/dsync_core/models/frame.dart';
import 'package:dsync/dsync_core/models/replica_spec.dart';
import 'package:dsync/dsync_core/models/rule_set.dart';
import 'package:dsync/dsync_core/models/scan_entry.dart';
import 'package:dsync/dsync_core/protocol/control_message.dart';
import 'package:dsync/dsync_core/protocol/frame_codec.dart';
import 'package:dsync/dsync_core/protocol/scan_result_codec.dart';
import 'package:dsync/dsync_core/protocol/stdio_channel.dart';
import 'package:dsync/dsync_core/protocol/version_handshake.dart';
import 'package:dsync/dsync_core/state_dir.dart';
import 'package:test/test.dart';

/// Drives the real `dsync agent --stdio` command as a child process, over
/// real OS pipes (SPEC §4.2, §11.1) — the one thing that can't be proven by
/// exercising `AgentServer`/`StdioChannel` in-process: that this process's
/// stdout carries *only* the frame stream, from the process's own point of
/// view, exactly like `ssh` sees it.
///
/// The binary is compiled once in [setUpAll] rather than run via `dart run`
/// per test, both for speed and so a `dart run` build message can never be
/// mistaken for protocol noise on the child's stdout.
void main() {
  late Directory binDir;
  late String binaryPath;

  setUpAll(() async {
    binDir = await Directory.systemTemp.createTemp('dsync_agent_bin_');
    binaryPath = '${binDir.path}/dsync_agent_test';
    final compile = await Process.run(Platform.resolvedExecutable, [
      'compile',
      'exe',
      'bin/dsync.dart',
      '-o',
      binaryPath,
    ]);
    if (compile.exitCode != 0) {
      fail('failed to compile bin/dsync.dart:\n${compile.stderr}');
    }
  });

  tearDownAll(() async {
    await binDir.delete(recursive: true);
  });

  group('dsync agent --stdio', () {
    late Directory tempRoot;
    late Directory stateHome;

    setUp(() async {
      tempRoot = await Directory.systemTemp.createTemp('dsync_agent_root_');
      stateHome = await Directory.systemTemp.createTemp('dsync_agent_state_');
    });

    tearDown(() async {
      await tempRoot.delete(recursive: true);
      await stateHome.delete(recursive: true);
    });

    /// Starts the compiled binary with an isolated `XDG_STATE_HOME`, so the
    /// lock file and archive `hello`'s `LocalAgent` opens (SPEC §4.3, §8.3)
    /// never touch this machine's real dsync state.
    Future<Process> startAgent() => Process.start(
      binaryPath,
      ['agent', '--stdio'],
      environment: {'XDG_STATE_HOME': stateHome.path},
    );

    test('a full handshake + hello + scan round-trip against a real temp '
        'root, then closing stdin ends the process cleanly', () async {
      await File('${tempRoot.path}/a.txt').writeAsString('hello');

      final process = await startAgent();
      final channel = StdioChannel(
        input: process.stdout.cast<Uint8List>(),
        output: process.stdin,
      );
      final frames = StreamIterator(FrameCodec().decode(channel.input));

      await performVersionHandshake(channel, frames);

      await channel.send(
        FrameCodec().encode(
          AgentRequest('hello', {
            'replica': replicaSpecToJson(
              ReplicaSpec(
                rootPath: tempRoot.path,
                profileId: 'agent-stdio-test',
                side: 'a',
                jobs: 2,
              ),
            ),
          }).toFrame(),
        ),
      );
      await frames.moveNext();
      final helloReply = AgentResult.fromFrame(frames.current);
      expect(helloReply, isA<AgentSuccess>());
      // task ee190c: the remote side's own `LocalAgent` resolves and
      // reports its real archive path — the initiator has no way to
      // `stat` it itself.
      expect(
        (helloReply as AgentSuccess).data['archivePath'],
        resolveArchiveLogPath(
          profileId: 'agent-stdio-test',
          side: 'a',
          environment: {'XDG_STATE_HOME': stateHome.path},
          platform: const LinuxStateDir(),
        ).path,
      );

      await channel.send(
        FrameCodec().encode(
          AgentRequest('scan', {'rules': ruleSetToJson(RuleSet())}).toFrame(),
        ),
      );
      await frames.moveNext();
      // A successful scan comes back as its own frame type, not a control
      // frame (SPEC §15.3, task 9551c4).
      expect(frames.current.type, FrameType.scanResult);
      final entries = decodeScanResult(frames.current.payload).entries;
      expect(entries.single.path, 'a.txt');
      expect(entries.single.reason, ScanReason.created);

      await process.stdin.close();
      final exitCode = await process.exitCode.timeout(
        const Duration(seconds: 10),
      );
      expect(exitCode, 0);
    });

    test(
      'a protocol version mismatch exits 3 with the mismatch on stderr',
      () async {
        final process = await startAgent();
        final stderrText = utf8.decoder.bind(process.stderr).join();

        // The agent sends its own version frame before it has seen ours
        // (SPEC §4.2), so read that off the wire, then reply with a version
        // it cannot speak.
        final frames = StreamIterator(
          FrameCodec().decode(process.stdout.cast<Uint8List>()),
        );
        await frames.moveNext();

        process.stdin.add(
          FrameCodec().encode(
            Frame(
              type: FrameType.control,
              payload: utf8.encode(jsonEncode({'version': -1})),
            ),
          ),
        );
        await process.stdin.flush();

        final exitCode = await process.exitCode.timeout(
          const Duration(seconds: 10),
        );
        expect(exitCode, 3);
        expect(await stderrText, contains('Protocol version mismatch'));
      },
    );
  });
}
