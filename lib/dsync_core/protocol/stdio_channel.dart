import 'dart:async';
import 'dart:io';

import 'package:dsync/dsync_core/protocol/channel.dart';

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
  final Stream<List<int>> _input;
  final IOSink _output;

  /// [input] and [output] default to this process's real stdin/stdout;
  /// overridable so this can be driven by fakes in a test without touching
  /// either — the process-level behavior (nothing else reaches the real
  /// stdout) is instead proven by driving a real child process over pipes
  /// (see `test/cli/commands/`).
  StdioChannel({Stream<List<int>>? input, IOSink? output})
    : _input = input ?? stdin,
      _output = output ?? stdout;

  @override
  Stream<List<int>> get input => _input;

  @override
  Future<void> send(List<int> bytes) async {
    _output.add(bytes);
    await _output.flush();
  }

  /// Closes the output side. There is no way for one end of a process's own
  /// stdio to force the *input* side closed — that happens when whatever is
  /// upstream (`ssh`, or the process that started this one) closes its end —
  /// so this only closes [_output], the one direction this side owns.
  @override
  Future<void> close() async {
    await _output.close();
  }
}
