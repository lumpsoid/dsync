import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

/// The [Tooltip] whose message is [message] — the match flutter_test's
/// byTooltip finder makes, for material_ui's [Tooltip]: that finder still
/// matches the SDK `package:flutter/material.dart` one, which the app no
/// longer builds.
Finder byTooltip(String message) => find.byWidgetPredicate(
  (widget) => widget is Tooltip && widget.message == message,
);
