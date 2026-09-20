import 'dart:typed_data';

import 'package:dsync/dsync_core/identity/enrolment_message.dart';
import 'package:test/test.dart';

/// [readEnrolmentMessage]'s wire behaviour, driven by plain streams rather
/// than sockets — the socket half of this protocol is covered end to end in
/// `enrolment_test.dart`.
///
/// The cap matters here more than anywhere else in the project: this is the
/// one read that happens before the peer has been authenticated by anything,
/// so an unbounded buffer is reachable by any stranger who finds the port.
void main() {
  Uint8List header(int length) {
    final out = Uint8List(4);
    ByteData.sublistView(out).setUint32(0, length, Endian.big);
    return out;
  }

  test('a complete message is returned', () async {
    final body = Uint8List.fromList([1, 2, 3, 4, 5]);
    final read = await readEnrolmentMessage(
      Stream.fromIterable([header(body.length), body]),
    );
    expect(read, body);
  });

  test('a message closed before it completes is refused', () async {
    expect(
      readEnrolmentMessage(
        Stream.fromIterable([
          header(5),
          Uint8List.fromList([1, 2]),
        ]),
      ),
      throwsFormatException,
    );
  });

  test('a declared length over the cap is refused before the body arrives', () {
    // Only the header is ever offered: refusing without waiting for a body is
    // the whole point — the decision is made on the announced size.
    expect(
      readEnrolmentMessage(
        Stream.fromIterable([header(maxEnrolmentMessageBytes + 1)]),
      ),
      throwsFormatException,
    );
  });

  test('a message exactly at the cap is still read', () async {
    final body = Uint8List(maxEnrolmentMessageBytes);
    body[maxEnrolmentMessageBytes - 1] = 7;
    final read = await readEnrolmentMessage(
      Stream.fromIterable([header(body.length), body]),
    );
    expect(read.length, maxEnrolmentMessageBytes);
    expect(read.last, 7);
  });

  test('more accumulated bytes than the cap allows is refused', () {
    // A truthful header followed by more bytes than any message may occupy:
    // the buffer, not the announced length, is what has to stop growing.
    expect(
      readEnrolmentMessage(
        Stream.fromIterable([
          header(maxEnrolmentMessageBytes),
          Uint8List(maxEnrolmentMessageBytes + 1),
        ]),
      ),
      throwsFormatException,
    );
  });
}
