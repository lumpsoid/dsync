import 'dart:convert';
import 'dart:typed_data';

import 'package:dsync/dsync_core/models/frame.dart';
import 'package:dsync/dsync_core/protocol/frame_codec.dart';
import 'package:flutter_test/flutter_test.dart';

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

    test('throws FormatException on an unknown type byte', () async {
      final bad = Uint8List.fromList([2, 0, 0, 0, 0]);

      await expectLater(
        codec.decode(Stream.value(bad)).toList(),
        throwsFormatException,
      );
    });
  });
}
