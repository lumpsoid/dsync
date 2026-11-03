import 'package:flutter/foundation.dart';

import 'core_link/core_link.dart';

/// How many lines of an error's stack the diagnostics log keeps: enough to
/// place it, short enough that one error loop cannot fill the log.
const stackLinesKept = 12;

/// Notes every error the head does not catch in the core's diagnostics log
/// (`CoreLink.noteDiagnostic`), so a release build — whose console no one
/// reads — still leaves something a user can attach to a bug report.
///
/// A framework error is still presented as before, and an uncaught async
/// one still reaches the engine's default report: this adds a record, it
/// handles nothing. A note the core cannot take — before `Init`, or with
/// the core gone — is let go: it must never raise an error of its own.
void noteUncaughtErrors(CoreLink core) {
  void note(String message) => core.noteDiagnostic(message).ignore();

  final present = FlutterError.onError;
  FlutterError.onError = (details) {
    present?.call(details);
    note(describeError('flutter error', details.exception, details.stack));
  };
  PlatformDispatcher.instance.onError = (error, stack) {
    note(describeError('dart error', error, stack));
    return false;
  };
}

/// One error as the diagnostics log keeps it: [kind], what was thrown, and
/// the top [stackLinesKept] lines of [stack].
String describeError(String kind, Object error, StackTrace? stack) {
  final frames = stack == null
      ? const <String>[]
      : '$stack'.split('\n').where((line) => line.trim().isNotEmpty);
  final kept = frames.take(stackLinesKept).toList();
  final cut = frames.length - kept.length;
  return [
    '$kind: $error',
    ...kept,
    if (cut > 0) '… $cut more frames',
  ].join('\n');
}
