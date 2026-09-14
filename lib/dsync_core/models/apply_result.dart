import 'package:dsync/dsync_core/models/plan.dart';

/// One path an [Applier] successfully applied.
class AppliedPath {
  final String path;
  final ActionType type;

  const AppliedPath({required this.path, required this.type});
}

/// One path an [Applier] could not apply (SPEC §7.6). The path is left in
/// whatever state it reached (temp files cleaned up) — that is the only
/// guarantee. Each action commits its two archives one after the other, so a
/// failure between them can leave one side already committed; SPEC §7.3 is
/// designed around exactly that gap, so it is safe, not a defect to fix here.
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
