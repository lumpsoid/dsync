import 'package:dsync/app/uncaught_errors.dart';
import 'package:test/test.dart';

/// What the diagnostics log keeps of an uncaught error.
void main() {
  test('keeps the error and the top of its stack', () {
    final stack = StackTrace.fromString(
      [for (var i = 0; i < stackLinesKept + 3; i++) '#$i frame $i'].join('\n'),
    );

    final lines = describeError(
      'dart error',
      StateError('boom'),
      stack,
    ).split('\n');

    expect(lines.first, 'dart error: Bad state: boom');
    expect(lines.skip(1).take(stackLinesKept), [
      for (var i = 0; i < stackLinesKept; i++) '#$i frame $i',
    ]);
    expect(lines.last, '… 3 more frames');
  });

  test('an error with no stack is the error alone', () {
    expect(
      describeError('flutter error', 'overflowed', null),
      'flutter error: overflowed',
    );
  });
}
