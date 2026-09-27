import 'package:dsync/app/path_text.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

/// The [PathText] drawing [path] — found by the stored path it holds, which
/// is what a page shows whatever its width lets the label be.
Finder pathText(String path) => find.byWidgetPredicate(
  (widget) => widget is PathText && widget.path == path,
);

/// What the [PathText] drawing [path] shows on screen: [path] itself when it
/// fits, otherwise its middle-elided label.
String shownPath(WidgetTester tester, String path) {
  final text = tester.widget<Text>(
    find.descendant(of: pathText(path), matching: find.byType(Text)),
  );
  return text.data ?? text.textSpan!.toPlainText();
}
