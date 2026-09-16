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

      final frames = await codec
          .decode(Stream.value(Uint8List.fromList([...f1, ...f2])))
          .toList();

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

    test('a decoded payload survives the chunks that follow it', () async {
      // The decoder buffers into one array it keeps reusing, and a fileBytes
      // payload outlives the decode loop — `Applier` streams it into the
      // destination's `writeFile` — so a payload has to be copied out of that
      // buffer, not handed out as a view onto it. Here the second frame is
      // written over exactly the bytes the first one's payload came from.
      final first = codec.encode(
        Frame(type: FrameType.fileBytes, payload: [1, 2, 3, 4]),
      );
      final second = codec.encode(
        Frame(type: FrameType.fileBytes, payload: [9, 9, 9, 9]),
      );

      final frames = await codec
          .decode(Stream.fromIterable([first, second]))
          .toList();

      expect(frames.first.payload, [1, 2, 3, 4]);
      expect(frames.last.payload, [9, 9, 9, 9]);
    });

    test('decodes a long run of frames that never line up with the chunks '
        'carrying them', () async {
      // Every chunk here leaves a partial frame buffered, so the decoder's
      // buffer is reused across all 300 of them — the undecoded tail slides
      // back to the front instead of the buffer growing with the stream.
      final payloads = [
        for (var i = 0; i < 300; i++) List.filled(i % 17 + 1, i % 256),
      ];
      final wire = BytesBuilder();
      for (final payload in payloads) {
        wire.add(
          codec.encode(Frame(type: FrameType.control, payload: payload)),
        );
      }
      final encoded = wire.takeBytes();

      Stream<Uint8List> chunked() async* {
        for (var i = 0; i < encoded.length; i += 37) {
          final end = i + 37;
          yield Uint8List.sublistView(
            encoded,
            i,
            end > encoded.length ? encoded.length : end,
          );
        }
      }

      final frames = await codec.decode(chunked()).toList();

      expect(frames.map((f) => f.payload), payloads);
    });

    test('decodes a multi-megabyte frame in linear time', () async {
      // A `scan` result crosses the wire as one control frame — ~189 bytes per
      // entry, so 18 MiB for a 100k-file replica. When each arriving chunk
      // re-copied the whole buffer, 8 MiB of it took ~10 s (and 16 MiB took
      // 34 s, peaking near a gigabyte); with a buffer that grows in place it
      // is ~50 ms. A one-second bound is far under the first and far over the
      // second, on a slow machine included.
      const payloadLength = 8 * 1024 * 1024;
      const chunkLength = 64 * 1024;
      final encoded = codec.encode(
        Frame(type: FrameType.control, payload: Uint8List(payloadLength)),
      );

      Stream<Uint8List> chunked() async* {
        for (var i = 0; i < encoded.length; i += chunkLength) {
          final end = i + chunkLength;
          yield Uint8List.sublistView(
            encoded,
            i,
            end > encoded.length ? encoded.length : end,
          );
        }
      }

      final watch = Stopwatch()..start();
      final frames = await codec.decode(chunked()).toList();
      watch.stop();

      expect(frames.single.payload, hasLength(payloadLength));
      expect(watch.elapsed, lessThan(const Duration(seconds: 1)));
    });

    test('throws FrameDecodeException on an unknown type byte', () async {
      // 4, not 3: 2 became `FrameType.scanResult` with task 9551c4 and 3
      // became `FrameType.heartbeat` with task 40812e.
      final bad = Uint8List.fromList([4, 0, 0, 0, 0]);

      await expectLater(
        codec.decode(Stream.value(bad)).toList(),
        throwsA(
          isA<FrameDecodeException>()
              .having((e) => e.message, 'message', contains('4'))
              .having((e) => e.received, 'received', [4, 0, 0, 0, 0])
              .having((e) => e.truncated, 'truncated', isFalse),
        ),
      );
    });

    test('round-trips a heartbeat frame (task 40812e)', () async {
      final encoded = codec.encode(
        const Frame(type: FrameType.heartbeat, payload: []),
      );

      final frames = await codec.decode(Stream.value(encoded)).toList();

      expect(frames.single.type, FrameType.heartbeat);
      expect(frames.single.payload, isEmpty);
    });

    test('decodes a scanResult frame (task 9551c4)', () async {
      final encoded = codec.encode(
        Frame(type: FrameType.scanResult, payload: [7, 8]),
      );

      final frames = await codec.decode(Stream.value(encoded)).toList();

      expect(frames.single.type, FrameType.scanResult);
      expect(frames.single.payload, [7, 8]);
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
