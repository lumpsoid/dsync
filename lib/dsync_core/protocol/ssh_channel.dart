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
  /// How many stderr lines are kept for [recentStderr]. Bounded so a chatty
  /// remote cannot grow this without limit over a long run.
  static const _stderrBufferLines = 50;

  final Process _process;
  final StreamController<String> _stderrLines = StreamController.broadcast();
  final List<String> _recentStderr = [];

  SshChannel._(this._process) {
    _process.stderr
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(_record, onDone: _stderrLines.close);
  }

  void _record(String line) {
    _recentStderr.add(line);
    if (_recentStderr.length > _stderrBufferLines) _recentStderr.removeAt(0);
    _stderrLines.add(line);
  }

  /// Lines `ssh` or the remote `dsync` process wrote to stderr, for
  /// diagnostics — not part of the protocol stream.
  ///
  /// A broadcast stream with no replay: anything written before a listener
  /// attached is not delivered here. Use [recentStderr] after the fact.
  Stream<String> get stderrLines => _stderrLines.stream;

  /// The most recent stderr lines, oldest first.
  ///
  /// Recorded from the moment the process starts, because the lines that
  /// explain a failed connection — `Permission denied`, `Host key
  /// verification failed` — arrive within milliseconds of the spawn, well
  /// before a caller knows it needs them. Without this they were written to a
  /// broadcast stream with no listener and dropped, leaving a failed run with
  /// nothing to report but a closed channel.
  List<String> get recentStderr => List.unmodifiable(_recentStderr);

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
    try {
      await _process.exitCode.timeout(_shutdownGrace);
    } on TimeoutException {
      // The remote agent exits when its stdin closes. One that does not —
      // wedged, or an ssh session that will not give up the connection — must
      // not hang the run that is trying to finish.
      _process.kill();
      await _process.exitCode;
    }
  }

  /// How long [close] waits for a clean exit before signalling the process.
  static const _shutdownGrace = Duration(seconds: 5);
}
