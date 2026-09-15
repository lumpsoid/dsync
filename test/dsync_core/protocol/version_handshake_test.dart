import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dsync/dsync_core/models/frame.dart';
import 'package:dsync/dsync_core/protocol/channel.dart';
import 'package:dsync/dsync_core/protocol/frame_codec.dart';
import 'package:dsync/dsync_core/protocol/version_handshake.dart';
import 'package:test/test.dart';

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

    test('quotes what the peer sent when its first bytes are not frames '
        'at all', () async {
      final (a, b) = _pairedChannels();
      await b.send(utf8.encode('Welcome to build-box!\nLast login: today\n'));

      await expectLater(
        performVersionHandshake(a, _frameIterator(a)),
        throwsA(
          isA<PeerNotSpeakingProtocolException>().having(
            (e) => e.toString(),
            'toString()',
            allOf(
              contains('Welcome to build-box!'),
              contains('Last login: today'),
              contains('stdout'),
              contains('~/.bashrc'),
            ),
          ),
        ),
      );
    });

    test('renders unprintable bytes rather than letting the peer drive the '
        'terminal', () async {
      final (a, b) = _pairedChannels();
      await b.send(
        Uint8List.fromList([...utf8.encode('hi\x1b[2Jthere'), 0x07]),
      );

      await expectLater(
        performVersionHandshake(a, _frameIterator(a)),
        throwsA(
          isA<PeerNotSpeakingProtocolException>().having(
            (e) => e.toString(),
            'toString()',
            allOf(contains('hi.[2Jthere'), isNot(contains('\x1b'))),
          ),
        ),
      );
    });

    test('leaves a decode failure after the handshake as the protocol bug it '
        'is', () async {
      final (a, b) = _pairedChannels();
      final frames = _frameIterator(a);

      await Future.wait([
        performVersionHandshake(a, frames),
        performVersionHandshake(b, _frameIterator(b)),
      ]);
      await b.send(utf8.encode('Welcome to build-box!\n'));

      // The raw codec failure, not a shell-chatter diagnosis: once the
      // handshake has succeeded, garbage on the wire is a protocol bug and
      // pointing the next debugger at ~/.bashrc would waste their time.
      await expectLater(
        frames.moveNext(),
        throwsA(isA<FrameDecodeException>()),
      );
    });

    test(
      'throws StateError when the channel closes before anything arrives',
      () async {
        final controller = StreamController<Uint8List>();
        final channel = _FakeChannel(
          outbox: StreamController<Uint8List>(),
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
  final aToB = StreamController<Uint8List>();
  final bToA = StreamController<Uint8List>();
  final a = _FakeChannel(outbox: aToB, input: bToA.stream);
  final b = _FakeChannel(outbox: bToA, input: aToB.stream);
  return (a, b);
}

/// A minimal [Channel] wiring two in-memory byte streams — just enough to
/// drive [performVersionHandshake] in isolation. The real shared in-memory
/// `Channel` (SPEC §14) is a separate task; this one stays test-local.
class _FakeChannel implements Channel {
  final StreamController<Uint8List> outbox;
  @override
  final Stream<Uint8List> input;

  _FakeChannel({required this.outbox, required this.input});

  @override
  Future<void> send(Uint8List bytes) async {
    outbox.add(bytes);
  }

  @override
  Future<void> close() async {
    await outbox.close();
  }
}
