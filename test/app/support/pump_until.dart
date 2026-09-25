import 'package:flutter_test/flutter_test.dart';

/// Drives work that straddles both clocks — real `dart:io` the page is
/// awaiting, and a frame that has to be built for its result to show —
/// until [reached] holds.
///
/// A widget test's body runs against a fake clock. Work it starts that
/// awaits real I/O needs real time to pass for the I/O to land (`runAsync`),
/// and its continuation, queued in the fake zone, only runs on a pump; so
/// this alternates the two. The pump moves the fake clock too, so a timer
/// the work sets on it fires rather than stalls.
///
/// Call it from the test body, never inside `tester.runAsync`: `runAsync`
/// does not nest. Bounded by [attempts], not by wall-clock time, so a slow
/// machine stretches the wait instead of failing it; a condition that never
/// holds fails the test with [what] rather than hanging it.
Future<void> pumpUntil(
  WidgetTester tester,
  bool Function() reached, {
  required String what,
  int attempts = 500,
}) async {
  for (var attempt = 0; attempt < attempts; attempt++) {
    if (reached()) return;
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
    await tester.pump(const Duration(milliseconds: 20));
  }
  fail('timed out waiting for $what');
}
