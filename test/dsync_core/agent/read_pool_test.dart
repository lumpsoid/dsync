import 'dart:io';
import 'dart:typed_data';

import 'package:dsync/dsync_core/agent/read_pool.dart';
import 'package:test/test.dart';

/// What can be pinned about a pool of isolates that read files: not how fast
/// it is — that is the device's on the day, and `ReadProbe` is where it is
/// measured — but that the bytes it returns are the file's, that the boundary
/// between the head it reads and the stream that follows loses nothing, and
/// that it lets go of its workers (task 9d2158 §19).
///
/// A leaked pool holds the test process open, so every pool built here is
/// closed in a tear-down. A test that hangs is this rule being broken.
void main() {
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('read_pool_test');
  });

  tearDown(() async {
    await tempDir.delete(recursive: true);
  });

  /// [size] bytes of a repeating pattern, so a chunk taken from the wrong
  /// offset is visible rather than merely different.
  Future<String> write(String name, int size) async {
    final file = File('${tempDir.path}/$name');
    await file.writeAsBytes([for (var i = 0; i < size; i++) i % 251]);
    return file.path;
  }

  Uint8List expected(int size) =>
      Uint8List.fromList([for (var i = 0; i < size; i++) i % 251]);

  ReadPool poolOf({int workers = 2, int blockBytes = 8}) {
    final pool = ReadPool(workers: workers, blockBytes: blockBytes);
    addTearDown(pool.close);
    return pool;
  }

  test('a file inside the block comes back whole and complete', () async {
    final path = await write('small.bin', 5);

    final head = await poolOf().read(path);

    expect(head.bytes, expected(5));
    expect(head.complete, isTrue, reason: 'a short read is end of file');
  });

  test('an empty file is complete with no bytes', () async {
    final path = await write('empty.bin', 0);

    final head = await poolOf().read(path);

    expect(head.bytes, isEmpty);
    expect(head.complete, isTrue);
  });

  test('a file past the block returns the block and says so', () async {
    final path = await write('big.bin', 20);

    final head = await poolOf(blockBytes: 8).read(path);

    expect(head.bytes, expected(20).sublist(0, 8));
    expect(
      head.complete,
      isFalse,
      reason: 'a full read cannot know it reached the end',
    );
  });

  test('a file exactly one block reads as incomplete, and the rest is '
      'empty rather than wrong', () async {
    // The one case where `complete` is pessimistic: the read filled the
    // buffer and end of file is indistinguishable from more to come. What
    // must not happen is bytes being lost or repeated, so the caller's
    // continuation from the head's length has to be empty.
    final path = await write('exact.bin', 8);

    final head = await poolOf(blockBytes: 8).read(path);
    final rest = await File(path).openRead(head.bytes.length).toList();

    expect(head.bytes, expected(8));
    expect(head.complete, isFalse);
    expect(rest.expand((chunk) => chunk), isEmpty);
  });

  test('head plus the stream from its length is the whole file', () async {
    final path = await write('joined.bin', 37);

    final head = await poolOf(blockBytes: 8).read(path);
    final rest = await File(path).openRead(head.bytes.length).toList();

    expect(
      [...head.bytes, ...rest.expand((chunk) => chunk)],
      expected(37),
      reason: 'the boundary between the pooled head and the stream',
    );
  });

  test('an unreadable path throws where a direct read would', () async {
    await expectLater(
      poolOf().read('${tempDir.path}/absent.bin'),
      throwsA(
        isA<FileSystemException>().having(
          (e) => e.path,
          'path',
          '${tempDir.path}/absent.bin',
        ),
      ),
    );
  });

  test('more requests than workers all complete, in one pool', () async {
    final paths = [for (var i = 0; i < 12; i++) await write('f$i.bin', i)];
    final pool = poolOf(workers: 2);

    final heads = await Future.wait([
      for (final path in paths) pool.read(path),
    ]);

    for (var i = 0; i < paths.length; i++) {
      // Files 8..11 are past the 8-byte block, so their head is the block —
      // which is also what makes this a queue test rather than twelve small
      // reads that happen to fit.
      expect(heads[i].bytes, expected(i < 8 ? i : 8), reason: 'f$i.bin');
      expect(heads[i].complete, i < 8, reason: 'f$i.bin');
    }
  });

  test('a closed pool refuses work rather than hanging', () async {
    final pool = ReadPool(workers: 1, blockBytes: 8);
    await pool.read(await write('one.bin', 3));
    await pool.close();

    expect(() => pool.read('${tempDir.path}/one.bin'), throwsStateError);
    await pool.close(); // idempotent
  });
}
