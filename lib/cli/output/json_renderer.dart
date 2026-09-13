import 'dart:convert';
import 'dart:io';

import 'package:dsync/dsync_core/models/plan.dart';
import 'package:dsync/dsync_core/models/run_event.dart';

/// Renders a `RunController` run as SPEC §11.4's `--json` stream: one JSON
/// object per line on stdout, one line per [RunEvent], each carrying a
/// `type` field naming which of the eight line shapes it is (`plan`,
/// `action`, `conflict`, `symlink`, `progress`, `result`, `summary`,
/// `error`).
///
/// `RunEvent` is a `sealed class`, so the switch in [render] is exhaustive:
/// the ninth line type task ee190c adds (`replicas`, carrying each side's
/// location, locality, resolved archive path, last-commit time, profile id
/// and `firstSync`) is one more case there, not a restructuring.
///
/// This renderer never writes to [err] — every [RunEvent] SPEC §11.4's
/// `--json` mode produces is one of the eight types above, all of which
/// belong on stdout, so there is no human text of this renderer's own to
/// divert ("Human text goes to stderr in this mode so stdout stays
/// parseable"). [err] is still accepted, unused, as a constructor parameter
/// so this renderer's shape matches the human renderer's at the call site,
/// and so a caller (or a test) holding its own reference can assert nothing
/// non-JSON ever reaches it.
class JsonRenderer {
  final IOSink out;
  final IOSink err;

  JsonRenderer({required this.out, required this.err});

  /// Encodes [event] as one JSON line and writes it, terminated by a single
  /// newline, to the stdout sink this renderer was built with.
  void render(RunEvent event) {
    final json = switch (event) {
      RunPlanEvent(:final plan) => {
        'type': 'plan',
        'actions': plan.actions.map(_actionToJson).toList(),
        'conflicts': plan.conflicts.map(_conflictToJson).toList(),
      },
      RunSkippedSymlinkEvent(:final path, :final onA) => {
        'type': 'symlink',
        'path': path,
        'onA': onA,
      },
      RunConflictEvent(:final conflict) => {
        'type': 'conflict',
        ..._conflictToJson(conflict),
      },
      RunActionEvent(:final action) => {
        'type': 'action',
        ..._actionToJson(action),
      },
      RunProgressEvent(:final completed, :final total) => {
        'type': 'progress',
        'completed': completed,
        'total': total,
      },
      RunResultEvent(
        :final path,
        :final type,
        :final error,
        :final succeeded,
      ) =>
        {
          'type': 'result',
          'path': path,
          'actionType': type.name,
          'succeeded': succeeded,
          if (error != null) 'error': error.toString(),
        },
      RunSummaryEvent(
        :final appliedCount,
        :final failedCount,
        :final conflictCount,
        :final skippedCount,
      ) =>
        {
          'type': 'summary',
          'appliedCount': appliedCount,
          'failedCount': failedCount,
          'conflictCount': conflictCount,
          'skippedCount': skippedCount,
        },
      RunErrorEvent(:final error) => {
        'type': 'error',
        'message': error.toString(),
      },
    };
    out.writeln(jsonEncode(json));
  }
}

/// One [PlanAction], as it appears standalone on an `action` line and nested
/// in a `plan` line's `actions` list. Keyed `actionType` rather than `type`:
/// the envelope's own `type` field already occupies that key on the same
/// line, and reusing it for [PlanAction.type] would silently overwrite it.
Map<String, dynamic> _actionToJson(PlanAction action) => {
  'path': action.path,
  'actionType': action.type.name,
  'bytes': action.bytes,
};

/// One [Conflict], as it appears standalone on a `conflict` line and nested
/// in a `plan` line's `conflicts` list. A side with no record of the path at
/// all (`onA`/`onB` null, per [Conflict]'s own doc comment) omits that key,
/// matching the null-omission convention `control_message.dart`'s `*ToJson`
/// helpers use.
Map<String, dynamic> _conflictToJson(Conflict conflict) => {
  'path': conflict.path,
  if (conflict.onA != null) 'onA': conflict.onA!.status.name,
  if (conflict.onB != null) 'onB': conflict.onB!.status.name,
};
