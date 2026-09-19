import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dsync/dsync_core/models/ssh_access.dart';
import 'package:dsync/dsync_core/protocol/channel.dart';
import 'package:dsync/dsync_core/protocol/flushed_sink.dart';

/// The argv passed to the `ssh` executable to reach [host] and start the
/// remote agent (SPEC §4.2).
///
/// [host] is handed to ssh exactly as given and is never examined here — it
/// may be a hostname, a `~/.ssh/config` alias, or a socket destination like
/// `unix/run/ssh-unix-local/socket` (see `LocationScheme.ssh`). Resolving it
/// is ssh's job, and duplicating any part of that resolution is how this
/// tool would come to disagree with the connection it just opened.
///
/// [SshAccess.options] go before the destination, where ssh reads its own
/// options; [SshAccess.command] takes the place of the bare `dsync`, for a
/// far side that keeps it somewhere the non-interactive PATH does not reach.
///
/// `-T` disables pseudo-terminal allocation: the connection carries the
/// framed binary protocol (SPEC §4.2), and a pty would echo input and
/// translate newlines, corrupting it.
List<String> sshArgsFor({
  required String host,
  String? user,
  SshAccess access = const SshAccess(),
}) => [
  ...access.options,
  '-T',
  user == null ? host : '$user@$host',
  access.command,
  'agent',
  '--stdio',
];

/// A [Channel] over an SSH session running `dsync agent --stdio` on a remote
/// host — the v0 transport (SPEC §4.2).
///
/// Spawns the system `ssh` binary and wraps its stdin/stdout as the byte
/// stream; `ssh`'s stderr is not part of the protocol and is surfaced
/// separately on [stderrLines] for diagnostics. Kept behind the [Channel]
/// interface, which is what let `SocketChannel` join it rather than replace
/// it — a head with no system `ssh` to spawn has a transport of its own now
/// (SPEC §4.2), and this one is still the right answer wherever ssh already
/// works.
class SshChannel implements Channel {
  /// How many stderr lines are kept for [recentStderr]. Bounded so a chatty
  /// remote cannot grow this without limit over a long run.
  static const _stderrBufferLines = 50;

  final Process _process;

  /// One write on the wire at a time, however many operations are sending,
  /// carrying every frame queued behind it (SPEC §4.2) — see [FlushedSink].
  late final FlushedSink _writer = FlushedSink(_process.stdin);

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

  /// Spawns `ssh` to reach [host] (as [user], if given) and starts the agent
  /// there, per [access] — see [sshArgsFor]. [executable] is overridable for
  /// tests.
  static Future<SshChannel> connect({
    required String host,
    String? user,
    SshAccess access = const SshAccess(),
    String executable = 'ssh',
  }) async {
    final process = await Process.start(
      executable,
      sshArgsFor(host: host, user: user, access: access),
    );
    return SshChannel._(process);
  }

  @override
  /// `Process.stdout` is declared `Stream<List<int>>` but emits [Uint8List] —
  /// it is a pipe, and the VM reads pipes into typed data. The cast is one
  /// type check per chunk, not per byte, and it is what lets `FrameCodec`
  /// buffer with a `memmove` (see [Channel]).
  @override
  Stream<Uint8List> get input => _process.stdout.cast<Uint8List>();

  @override
  Future<void> send(Uint8List bytes) => _writer.send(bytes);

  /// What [FlushedSink] actually wrote, below the number of `send` calls by
  /// the frames that left in company (SPEC §17).
  @override
  int get writes => _writer.writes;

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
