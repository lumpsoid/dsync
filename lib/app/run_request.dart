import 'core_link/models/run_target.dart';

/// What the Run setup page hands to the Run page: what to sync and how
/// (SPEC §11.2, §11.3), as plain values.
///
/// Constructed in exactly one place — `RunSetupController.start()` — after
/// every field the head checks has validated. The Run feature hands
/// [target], [dryRun] and [address] to the core's `startRun` verbatim;
/// [deviceName] titles the page. What the run syncs - every entry's roots -
/// the page learns from the core's views of the run, not from here.
///
/// [address] is SPEC §4.4's manual re-entry hatch, `host` or `host:port`
/// as typed; `null` means the paired device's cached address.
class RunRequest {
  const RunRequest({
    required this.target,
    required this.deviceName,
    required this.address,
    required this.dryRun,
  });

  /// The saved profile to run, or — for a run nobody named — the pair
  /// itself.
  final RunTarget target;

  /// This device's own name for the peer, as the page titles the run.
  final String deviceName;

  /// Where to dial the peer this once, or `null` for where it was last
  /// reached.
  final String? address;

  /// SPEC §11.2 `--dry-run`: show the plan, apply nothing.
  final bool dryRun;
}
