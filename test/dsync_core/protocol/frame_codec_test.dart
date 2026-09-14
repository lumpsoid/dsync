import 'dart:convert';
import 'dart:typed_data';

import 'package:dsync/dsync_core/models/frame.dart';
import 'package:dsync/dsync_core/protocol/frame_codec.dart';
import 'package:test/test.dart';

void main() {
  final codec = FrameCodec();

  group('encode', () {
    test(
      'control frames encode as type 0 + 4-byte big-endian length + payload',
      () {
        final bytes = codec.encode(
          Frame(type: FrameType.control, payload: [1, 2, 3]),
        );
        expect(bytes, [0, 0, 0, 0, 3, 1, 2, 3]);
      },
    );

    test('fileBytes frames encode as type 1', () {
      final bytes = codec.encode(
        Frame(type: FrameType.fileBytes, payload: [9]),
      );
      expect(bytes, [1, 0, 0, 0, 1, 9]);
    });

    test('an empty payload encodes as a zero-length frame', () {
      final bytes = codec.encode(
        Frame(type: FrameType.control, payload: const []),
      );
      expect(bytes, [0, 0, 0, 0, 0]);
    });
  });

  group('decode', () {
    test('decodes a single frame delivered in one chunk', () async {
      final encoded = codec.encode(
        Frame(type: FrameType.control, payload: utf8.encode('hi')),
      );

      final frames = await codec.decode(Stream.value(encoded)).toList();

      expect(frames, hasLength(1));
      expect(frames.single.type, FrameType.control);
      expect(utf8.decode(frames.single.payload), 'hi');
    });

    test(
      'decodes a frame whose bytes arrive split across multiple chunks',
      () async {
        final encoded = codec.encode(
          Frame(type: FrameType.fileBytes, payload: [1, 2, 3, 4, 5]),
        );
        final chunks = [
          encoded.sublist(0, 3),
          encoded.sublist(3, 6),
          encoded.sublist(6),
        ];

        final frames = await codec.decode(Stream.fromIterable(chunks)).toList();

        expect(frames, hasLength(1));
        expect(frames.single.type, FrameType.fileBytes);
        expect(frames.single.payload, [1, 2, 3, 4, 5]);
      },
    );

    test('decodes multiple frames delivered in a single chunk', () async {
      final f1 = codec.encode(Frame(type: FrameType.control, payload: [1]));
      final f2 = codec.encode(
        Frame(type: FrameType.fileBytes, payload: [2, 3]),
      );

      final frames = await codec.decode(Stream.value([...f1, ...f2])).toList();

      expect(frames.map((f) => f.type), [
        FrameType.control,
        FrameType.fileBytes,
      ]);
      expect(frames.map((f) => f.payload), [
        [1],
        [2, 3],
      ]);
    });

    test('round-trips an empty payload', () async {
      final encoded = codec.encode(
        Frame(type: FrameType.control, payload: const []),
      );

      final frames = await codec.decode(Stream.value(encoded)).toList();

      expect(frames.single.payload, isEmpty);
    });

    test('throws FrameDecodeException on an unknown type byte', () async {
      final bad = Uint8List.fromList([2, 0, 0, 0, 0]);

      await expectLater(
        codec.decode(Stream.value(bad)).toList(),
        throwsA(
          isA<FrameDecodeException>()
              .having((e) => e.message, 'message', contains('2'))
              .having((e) => e.received, 'received', [2, 0, 0, 0, 0])
              .having((e) => e.truncated, 'truncated', isFalse),
        ),
      );
    });

    test('fails on the header rather than waiting out the bogus length a '
        'text stream declares', () async {
      // "Welcome" read as a frame is type `W` with a payload of `elco`
      // bytes — 1.7 GB. Nothing would ever complete it, so a decoder that
      // checked the type only after the payload arrived would sit here in
      // silence until the connection closed.
      final banner = Uint8List.fromList(utf8.encode('Welcome to build-box!\n'));

      await expectLater(
        codec.decode(Stream.value(banner)).toList(),
        throwsA(
          isA<FrameDecodeException>().having(
            (e) => utf8.decode(e.received),
            'received',
            'Welcome to build-box!\n',
          ),
        ),
      );
    });

    test('keeps only a glance of a long undecodable stream', () async {
      final chatty = Uint8List.fromList(utf8.encode('W' * 1000));

      await expectLater(
        codec.decode(Stream.value(chatty)).toList(),
        throwsA(
          isA<FrameDecodeException>()
              .having((e) => e.received, 'received', hasLength(256))
              .having((e) => e.truncated, 'truncated', isTrue),
        ),
      );
    });
  });
}
