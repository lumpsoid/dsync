import 'dart:async';
import 'dart:convert';

import 'package:dsync/dsync_core/models/frame.dart';
import 'package:dsync/dsync_core/protocol/channel.dart';
import 'package:dsync/dsync_core/protocol/frame_codec.dart';
import 'package:dsync/dsync_core/protocol/version_handshake.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('performVersionHandshake', () {
    test('succeeds when both ends speak the same version', () async {
      final (a, b) = _pairedChannels();

      await Future.wait([
        performVersionHandshake(a, _frameIterator(a)),
        performVersionHandshake(b, _frameIterator(b)),
      ]);
    });

    test('throws ProtocolVersionMismatchException when the peer sends a '
        'different version', () async {
      final (a, b) = _pairedChannels();
      await b.send(
        FrameCodec().encode(
          Frame(
            type: FrameType.control,
            payload: utf8.encode(jsonEncode({'version': 99})),
          ),
        ),
      );

      await expectLater(
        performVersionHandshake(a, _frameIterator(a)),
        throwsA(
          isA<ProtocolVersionMismatchException>()
              .having((e) => e.local, 'local', protocolVersion)
              .having((e) => e.remote, 'remote', 99),
        ),
      );
    });

    test(
      'throws StateError when the channel closes before anything arrives',
      () async {
        final controller = StreamController<List<int>>();
        final channel = _FakeChannel(
          outbox: StreamController<List<int>>(),
          input: controller.stream,
        );
        final frames = _frameIterator(channel);

        final result = performVersionHandshake(channel, frames);
        final expectation = expectLater(result, throwsStateError);
        await controller.close();

        await expectation;
      },
    );
  });
}

StreamIterator<Frame> _frameIterator(Channel channel) =>
    StreamIterator(FrameCodec().decode(channel.input));

(Channel, Channel) _pairedChannels() {
  final aToB = StreamController<List<int>>();
  final bToA = StreamController<List<int>>();
  final a = _FakeChannel(outbox: aToB, input: bToA.stream);
  final b = _FakeChannel(outbox: bToA, input: aToB.stream);
  return (a, b);
}

/// A minimal [Channel] wiring two in-memory byte streams — just enough to
/// drive [performVersionHandshake] in isolation. The real shared in-memory
/// `Channel` (SPEC §14) is a separate task; this one stays test-local.
class _FakeChannel implements Channel {
  final StreamController<List<int>> outbox;
  @override
  final Stream<List<int>> input;

  _FakeChannel({required this.outbox, required this.input});

  @override
  Future<void> send(List<int> bytes) async {
    outbox.add(bytes);
  }

  @override
  Future<void> close() async {
    await outbox.close();
  }
}
