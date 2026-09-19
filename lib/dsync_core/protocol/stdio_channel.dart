import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:dsync/dsync_core/protocol/channel.dart';
import 'package:dsync/dsync_core/protocol/flushed_sink.dart';

/// A [Channel] over this process's own stdin/stdout (SPEC §4.2) — the other
/// side of the transport [SshChannel] speaks to a spawned `ssh` process, from
/// inside the process `ssh` (or, later, some other transport, SPEC §16)
/// starts on the remote host as `dsync agent --stdio`.
///
/// **Load-bearing, not a style preference.** Once this channel exists, stdout
/// is the entire protocol stream for the rest of the process's life: every
/// byte written there is parsed by the peer as a frame. Nothing else may
/// write to stdout after this point — a stray `print()`, a library that logs
/// to stdout by default, anything — splices arbitrary bytes into the frame
/// stream. `FrameCodec` has no way to tell that apart from a genuinely
/// corrupt frame, so the failure surfaces downstream looking exactly like a
/// protocol bug, with nothing pointing back at the real cause. Diagnostics
/// belong on stderr, the same reasoning as SPEC §11.4's human text under
/// `--json`.
class StdioChannel implements Channel {
  final Stream<Uint8List> _input;
  final IOSink _output;

  /// [input] and [output] default to this process's real stdin/stdout;
  /// overridable so this can be driven by fakes in a test without touching
  /// either — the process-level behavior (nothing else reaches the real
  /// stdout) is instead proven by driving a real child process over pipes
  /// (see `test/cli/commands/`).
  /// [stdin] is declared `Stream<List<int>>` but emits [Uint8List]; see
  /// `SshChannel.input` for why the cast is worth making.
  StdioChannel({Stream<Uint8List>? input, IOSink? output})
    : _input = input ?? stdin.cast<Uint8List>(),
      _output = output ?? stdout;

  /// One write on the wire at a time, however many operations are sending,
  /// carrying every frame queued behind it (SPEC §4.2) — see [FlushedSink].
  late final FlushedSink _writer = FlushedSink(_output);

  @override
  Stream<Uint8List> get input => _input;

  @override
  Future<void> send(Uint8List bytes) => _writer.send(bytes);

  /// What [FlushedSink] actually wrote, below the number of `send` calls by
  /// the frames that left in company (SPEC §17).
  @override
  int get writes => _writer.writes;

  /// Closes the output side. There is no way for one end of a process's own
  /// stdio to force the *input* side closed — that happens when whatever is
  /// upstream (`ssh`, or the process that started this one) closes its end —
  /// so this only closes [_output], the one direction this side owns.
  @override
  Future<void> close() async {
    await _output.close();
  }
}
