import 'package:dsync/dsync_core/models/plan.dart';

/// One path an [Applier] successfully applied.
class AppliedPath {
  final String path;
  final ActionType type;

  const AppliedPath({required this.path, required this.type});
}

/// One path an [Applier] could not apply (SPEC §7.6). The path is left in
/// whatever state it reached; neither archive was committed for it.
class FailedPath {
  final String path;
  final ActionType type;
  final Object error;

  const FailedPath({
    required this.path,
    required this.type,
    required this.error,
  });
}

/// The outcome of applying a [Plan]: which paths succeeded and which failed
/// and why (SPEC §7.6). Consumed by `RunController` for its `result`/
/// `summary` events and, eventually, the CLI exit code (SPEC §11.5) — this
/// type only records facts, it makes no exit-code decision itself.
class ApplyResult {
  final List<AppliedPath> applied;
  final List<FailedPath> failed;

  const ApplyResult({required this.applied, required this.failed});
}
