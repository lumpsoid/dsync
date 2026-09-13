import 'dart:async';
import 'dart:io';

import 'package:dsync/dsync_core/protocol/stdio_channel.dart';
import 'package:test/test.dart';

/// Unit-level coverage for [StdioChannel] with the real stdin/stdout swapped
/// for fakes, via the constructor's injection seam. The one thing that can't
/// be proven this way — that nothing *else* in the built binary reaches the
/// real stdout once this channel exists — is instead proven end to end by
/// driving a real child process over pipes (`test/cli/commands/`).
void main() {
  group('StdioChannel', () {
    test('input surfaces exactly what the injected stream produces', () async {
      final channel = StdioChannel(
        input: Stream.fromIterable([
          [1, 2, 3],
          [4, 5],
        ]),
        output: IOSink(StreamController<List<int>>().sink),
      );

      final chunks = await channel.input.toList();

      expect(chunks, [
        [1, 2, 3],
        [4, 5],
      ]);
    });

    test('send writes and flushes onto the injected output', () async {
      final received = <int>[];
      final controller = StreamController<List<int>>();
      controller.stream.listen(received.addAll);
      final channel = StdioChannel(
        input: const Stream.empty(),
        output: IOSink(controller.sink),
      );

      await channel.send([9, 8, 7]);

      expect(received, [9, 8, 7]);
    });

    test('multiple sends arrive in order on the injected output', () async {
      final received = <int>[];
      final controller = StreamController<List<int>>();
      controller.stream.listen(received.addAll);
      final channel = StdioChannel(
        input: const Stream.empty(),
        output: IOSink(controller.sink),
      );

      await channel.send([1]);
      await channel.send([2]);

      expect(received, [1, 2]);
    });

    test('close closes the injected output', () async {
      final controller = StreamController<List<int>>();
      var done = false;
      controller.stream.listen((_) {}, onDone: () => done = true);
      final channel = StdioChannel(
        input: const Stream.empty(),
        output: IOSink(controller.sink),
      );

      await channel.close();

      expect(done, isTrue);
    });
  });
}
