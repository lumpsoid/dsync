import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// An [IOSink] over an in-memory buffer, so a test reads what a command
/// printed without a real stdout/stderr.
///
/// The same shape `json_renderer_test.dart` keeps as a private
/// `_BufferSink`, made shared here because `test/cli/commands/pair_*`
/// exercises the same need across several files (CLAUDE.md: "extract a rule
/// out of its caller when it is reused") — `json_renderer_test.dart` itself
/// is left as it is, since it is the one file that ever needed it before
/// this.
///
/// Implements [StreamConsumer] directly (rather than forwarding through a
/// second [StreamController]) so its `addStream` only completes once every
/// chunk has actually been decoded into [_buffer] — `flush()` then really
/// means "everything written so far is in [_buffer]", with no async gap for
/// a scripted multi-event run to race.
class BufferSink implements StreamConsumer<List<int>> {
  final StringBuffer _buffer = StringBuffer();
  late final IOSink sink = IOSink(this);

  @override
  Future<void> addStream(Stream<List<int>> stream) async {
    await for (final chunk in stream) {
      _buffer.write(utf8.decode(chunk));
    }
  }

  @override
  Future<void> close() async {}

  /// Flushes [sink] so every `write`/`writeln` so far has reached [_buffer],
  /// then returns its contents.
  Future<String> contents() async {
    await sink.flush();
    return _buffer.toString();
  }
}
