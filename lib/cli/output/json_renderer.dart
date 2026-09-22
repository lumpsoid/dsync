import 'dart:convert';
import 'dart:io';

import 'package:dsync/cli/output/human_renderer.dart';
import 'package:dsync/dsync_core/models/location.dart';
import 'package:dsync/dsync_core/models/plan.dart';
import 'package:dsync/dsync_core/models/replica_info.dart';
import 'package:dsync/dsync_core/models/run_event.dart';
import 'package:dsync/dsync_core/models/scan_result.dart';
import 'package:dsync/dsync_core/models/skipped_path.dart';

/// Renders a `RunController` run as SPEC §11.4's `--json` stream: one JSON
/// object per line on stdout, one line per [RunEvent], each carrying a
/// `type` field naming which of the line shapes it is (`replicas`, `plan`,
/// `action`, `conflict`, `symlink`, `unreadable`, `caseFoldCollision` (SPEC
/// §16), `scanTally`, `progress`, `result`, `summary`, `error`).
/// [RunSkippedPathEvent] is the one event that maps to more than one of them
/// — see [render]'s own case for why.
///
/// `RunEvent` is a `sealed class`, so the switch in [render] is exhaustive:
/// the compiler pointed at this file (and `HumanRenderer`) as exactly what
/// task ee190c's new `RunReplicasEvent` needed to touch.
///
/// This renderer never writes to [err] — every [RunEvent] SPEC §11.4's
/// `--json` mode produces is one of the types above, all of which
/// belong on stdout, so there is no human text of this renderer's own to
/// divert ("Human text goes to stderr in this mode so stdout stays
/// parseable"). [err] is still accepted, unused, as a constructor parameter
/// so this renderer's shape matches the human renderer's at the call site,
/// and so a caller (or a test) holding its own reference can assert nothing
/// non-JSON ever reaches it.
class JsonRenderer {
  final IOSink out;
  final IOSink err;

  /// This run's profile id (SPEC §8.1, §8.3) — a profile's name, or the
  /// derived `adhoc-<16 hex>` (`EffectiveOptions`'s own doc comment) — on
  /// every `replicas` line (task ee190c's DECIDED).
  final String profileId;

  /// Replica A's and B's [ReplicaDiagnostics] — only [ReplicaDiagnostics.location]
  /// and [ReplicaDiagnostics.locality] are read here; [ReplicaDiagnostics.archivePath]
  /// is deliberately not, since a remote side's authoritative archive path is
  /// the one that comes back on the `replicas` event itself
  /// ([ReplicaInfo.archivePath]), not the initiator-side label this object
  /// carries for `HumanRenderer`'s verbose preamble. Independently nullable,
  /// matching `HumanRenderer`'s own convention: a `replicas` line still
  /// renders, minus whichever side's location/locality it has no diagnostics
  /// for.
  final ReplicaDiagnostics? diagnosticsA;
  final ReplicaDiagnostics? diagnosticsB;

  JsonRenderer({
    required this.out,
    required this.err,
    required this.profileId,
    this.diagnosticsA,
    this.diagnosticsB,
  });

  /// Encodes [event] as one JSON line and writes it, terminated by a single
  /// newline, to the stdout sink this renderer was built with.
  void render(RunEvent event) {
    final json = switch (event) {
      RunReplicasEvent(:final infoA, :final infoB) => {
        'type': 'replicas',
        'profileId': profileId,
        'a': _replicaSideToJson(infoA, diagnosticsA),
        'b': _replicaSideToJson(infoB, diagnosticsB),
        // SPEC §6, "a path one side has never seen": whenever either side
        // has no archive at all, every path this run touches falls into
        // that case, so the whole run behaves like a first sync of the
        // pair. Facts only (task ee190c's DECIDED) — the human-readable
        // "a file present on one side only is copied, never deleted" note
        // is `HumanRenderer`'s job, not a string here.
        'firstSync':
            infoA.lastCommitTime == null || infoB.lastCommitTime == null,
      },
      RunPlanEvent(:final plan) => {
        'type': 'plan',
        'actions': plan.actions.map(_actionToJson).toList(),
        'conflicts': plan.conflicts.map(_conflictToJson).toList(),
      },
      RunScanTallyEvent(:final tallyA, :final tallyB) => {
        'type': 'scanTally',
        'a': _scanReasonTallyToJson(tallyA),
        'b': _scanReasonTallyToJson(tallyB),
      },
      // One line *type* per SkippedReason, not one shared type with a
      // `reason` field (task 37bf4f): SPEC §11.4 fixes the set of `type`
      // values, and a consumer filtering for `symlink` is filtering for a
      // thing that is normal on every run — silently widening that type to
      // also mean "this file did not sync" would change what an existing
      // filter matches. Adding `unreadable` or `caseFoldCollision` (SPEC
      // §16) alongside cannot.
      RunSkippedPathEvent(:final skipped, :final onA) => {
        'type': switch (skipped.reason) {
          SkippedReason.symlink => 'symlink',
          SkippedReason.unreadable => 'unreadable',
          SkippedReason.caseFoldCollision => 'caseFoldCollision',
        },
        'path': skipped.path,
        'onA': onA,
        'detail': skipped.detail,
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
        :final unreadableCount,
      ) =>
        {
          'type': 'summary',
          'appliedCount': appliedCount,
          'failedCount': failedCount,
          'conflictCount': conflictCount,
          'skippedCount': skippedCount,
          'unreadableCount': unreadableCount,
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

/// One side's [ScanReasonTally] (SPEC §5.2, §11.4, task 1fd42b), as it
/// appears nested under `a`/`b` on a `scanTally` line. Every count,
/// unconditionally — no null-omission here, unlike [_conflictToJson]'s
/// `onA`/`onB`: every [ScanReason] always has a count (zero when a side had
/// none), there is no "this side has nothing to say" case to distinguish.
Map<String, dynamic> _scanReasonTallyToJson(ScanReasonTally tally) => {
  'metadataMatched': tally.metadataMatched,
  'hashMatched': tally.hashMatched,
  'modified': tally.modified,
  'created': tally.created,
  'deleted': tally.deleted,
  'untrusted': tally.untrusted,
};

/// One [Conflict], as it appears standalone on a `conflict` line and nested
/// in a `plan` line's `conflicts` list. A side with no record of the path at
/// all (`onA`/`onB` null, per [Conflict]'s own doc comment) omits that key
/// (and its paired `onAReason`/`onBReason`), matching the null-omission
/// convention `control_message.dart`'s `*ToJson` helpers use.
///
/// `onAReason`/`onBReason` (task 8a3ff1) carry [ScanEntry.reason] — which of
/// SPEC §5.2's branches produced that side's status — unconditionally
/// alongside `onA`/`onB`, not gated behind `--verbose` the way
/// `HumanRenderer` gates it: `--json` is machine-readable and this is a fact
/// about the scan, not commentary for a human, and SPEC §11.4 fixes the
/// `conflict` line's type rather than its field set, so adding a field here
/// stays inside that contract where inventing a tenth line type would not.
Map<String, dynamic> _conflictToJson(Conflict conflict) => {
  'path': conflict.path,
  if (conflict.onA != null) 'onA': conflict.onA!.status.name,
  if (conflict.onA != null) 'onAReason': conflict.onA!.reason.name,
  if (conflict.onB != null) 'onB': conflict.onB!.status.name,
  if (conflict.onB != null) 'onBReason': conflict.onB!.reason.name,
};

/// One side of a `replicas` line (task ee190c's DECIDED): this side's
/// location and locality (from [diagnostics], when supplied), plus its
/// resolved archive path and last-commit time (from [info] — the side's own
/// `hello` reply, the only place a remote side's archive path is
/// authoritative). Every key is independently omitted rather than emitted
/// `null`, matching this file's existing null-omission convention
/// ([_conflictToJson]).
Map<String, dynamic> _replicaSideToJson(
  ReplicaInfo info,
  ReplicaDiagnostics? diagnostics,
) => {
  if (diagnostics != null) 'location': _locationToJson(diagnostics.location),
  if (diagnostics != null) 'locality': diagnostics.locality.name,
  if (info.archivePath != null) 'archivePath': info.archivePath,
  if (info.lastCommitTime != null)
    'lastCommitTime': info.lastCommitTime!.toIso8601String(),
};

/// [location] exactly as resolved into this side (no expansion, no
/// canonicalization) — `path`, plus whichever of `host`/`user`/`socket`/`peer`
/// SPEC §2's form it was written in actually has.
///
/// A `unix://` replica reports `socket`, and a `peer://` one reports `peer`,
/// neither as `host`: all three are the same field on [Location] (see its doc
/// comment — one "where" per location, read according to the scheme), but
/// they are not the same fact, and a consumer that reads `host` expecting
/// something it could connect to over the network would be told a filesystem
/// path for one and a device name resolved through the paired-device store
/// for the other. The key that is present is what says which kind of
/// destination this is, the same way SPEC §11.4's other lines omit a key
/// rather than emit a null.
Map<String, dynamic> _locationToJson(
  Location location,
) => switch (location.scheme) {
  LocationScheme.unix => {'path': location.path, 'socket': location.socketPath},
  LocationScheme.peer => {'path': location.path, 'peer': location.deviceName},
  LocationScheme.ssh || LocationScheme.inferred => {
    'path': location.path,
    if (location.host != null) 'host': location.host,
    if (location.user != null) 'user': location.user,
  },
};
