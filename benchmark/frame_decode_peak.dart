// Scratch benchmark for task 2a0d9a — what decoding one large frame costs in
// transient memory, the figure quoted in `frame_codec.dart`. Not part of the
// build.
//
// The chunks are generated one at a time from a single reused 64 KiB source
// buffer, so nothing but the decoder itself is resident: the high-water mark
// this prints is the decoder's own peak over the run, not the cost of holding
// a 16 MiB frame to feed it.
//
//   dart run benchmark/frame_decode_peak.dart
import 'dart:io';
import 'dart:typed_data';

import 'package:dsync/dsync_core/protocol/frame_codec.dart';

const payloadLength = 16 * 1024 * 1024;
const chunkLength = 64 * 1024;

void main() {
  final baseline = ProcessInfo.currentRss;
  final decoder = FrameDecoder();
  final source = Uint8List(chunkLength);

  final header = Uint8List(9);
  ByteData.sublistView(header, 5).setUint32(0, payloadLength, Endian.big);

  final watch = Stopwatch()..start();
  var frames = decoder.add(header).length;
  for (var sent = 0; sent < payloadLength; sent += chunkLength) {
    final room = payloadLength - sent;
    frames += decoder
        .add(
          room < chunkLength ? Uint8List.sublistView(source, 0, room) : source,
        )
        .length;
  }
  watch.stop();

  final peak = ProcessInfo.maxRss - baseline;
  stdout.writeln(
    'frames=$frames  payload=${payloadLength >> 20} MiB  '
    'chunk=${chunkLength >> 10} KiB  '
    'elapsed=${watch.elapsedMilliseconds} ms  '
    'peak=${(peak / (1024 * 1024)).toStringAsFixed(1)} MiB',
  );
}
