import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dsync/dsync_core/protocol/channel.dart';

/// The argv passed to the `ssh` executable to reach [host] and start the
/// remote agent (SPEC §4.2).
///
/// `-T` disables pseudo-terminal allocation: the connection carries the
/// framed binary protocol (SPEC §4.2), and a pty would echo input and
/// translate newlines, corrupting it.
List<String> sshArgsFor({
  required String host,
  String? user,
  List<String> extraArgs = const [],
}) => [
  ...extraArgs,
  '-T',
  user == null ? host : '$user@$host',
  'dsync',
  'agent',
  '--stdio',
];

/// A [Channel] over an SSH session running `dsync agent --stdio` on a remote
/// host — the v0 transport (SPEC §4.2).
///
/// Spawns the system `ssh` binary and wraps its stdin/stdout as the byte
/// stream; `ssh`'s stderr is not part of the protocol and is surfaced
/// separately on [stderrLines] for diagnostics. Kept behind the [Channel]
/// interface so a Dart SSH client or a socket can replace it later, for the
/// Flutter head (SPEC §16).
class SshChannel implements Channel {
  final Process _process;
  final StreamController<String> _stderrLines = StreamController.broadcast();

  SshChannel._(this._process) {
    _process.stderr
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(_stderrLines.add, onDone: _stderrLines.close);
  }

  /// Lines `ssh` or the remote `dsync` process wrote to stderr, for
  /// diagnostics — not part of the protocol stream.
  Stream<String> get stderrLines => _stderrLines.stream;

  /// Spawns `ssh` to reach [host] (as [user], if given) and starts
  /// `dsync agent --stdio` there. [extraArgs] are inserted before the
  /// destination, e.g. `-p`/`-i`. [executable] is overridable for tests.
  static Future<SshChannel> connect({
    required String host,
    String? user,
    List<String> extraArgs = const [],
    String executable = 'ssh',
  }) async {
    final process = await Process.start(
      executable,
      sshArgsFor(host: host, user: user, extraArgs: extraArgs),
    );
    return SshChannel._(process);
  }

  @override
  Stream<List<int>> get input => _process.stdout;

  @override
  Future<void> send(List<int> bytes) async {
    _process.stdin.add(bytes);
    await _process.stdin.flush();
  }

  @override
  Future<void> close() async {
    await _process.stdin.close();
    await _process.exitCode;
  }
}
