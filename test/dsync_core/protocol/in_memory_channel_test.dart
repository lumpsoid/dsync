import 'dart:convert';

import 'package:dsync/dsync_core/protocol/in_memory_channel.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('bytes sent on one end arrive on the other\'s input', () async {
    final (a, b) = InMemoryChannel.pair();

    final received = b.input.first;
    await a.send(utf8.encode('hello'));

    expect(utf8.decode(await received), 'hello');
  });

  test('each end is independent: sends flow in both directions', () async {
    final (a, b) = InMemoryChannel.pair();

    final aReceived = a.input.first;
    final bReceived = b.input.first;
    await a.send(utf8.encode('to b'));
    await b.send(utf8.encode('to a'));

    expect(utf8.decode(await bReceived), 'to b');
    expect(utf8.decode(await aReceived), 'to a');
  });

  test('multiple sends arrive in order', () async {
    final (a, b) = InMemoryChannel.pair();

    final received = b.input.take(2).toList();
    await a.send(utf8.encode('first'));
    await a.send(utf8.encode('second'));

    final chunks = await received;
    expect(chunks.map(utf8.decode), ['first', 'second']);
  });

  test('closing one end ends the other\'s input stream', () async {
    final (a, b) = InMemoryChannel.pair();

    final done = b.input.isEmpty;
    await a.close();

    expect(await done, isTrue);
  });
}
