import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// What the page puts on the platform clipboard during this test, in
/// order — read off the platform channel, where `Clipboard.setData` goes,
/// so a copy action is asserted by the exact string it hands the system.
///
/// The channel's handler is the test binding's, shared by every test in the
/// file, so it is taken down again when the test ends.
List<String> recordClipboard(WidgetTester tester) {
  final copied = <String>[];
  tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
    SystemChannels.platform,
    (call) async {
      if (call.method == 'Clipboard.setData') {
        copied.add((call.arguments as Map)['text'] as String);
      }
      return null;
    },
  );
  addTearDown(
    () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      null,
    ),
  );
  return copied;
}
