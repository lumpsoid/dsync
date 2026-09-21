import 'package:dsync/dsync_core/models/paired_device.dart';

/// What the Run setup page hands to the Run page: the two locations of a
/// run and how to run it (SPEC §11.2, §11.3), as plain values.
///
/// Constructed in exactly one place — `RunSetupController.start()` — after
/// every field has validated, so a request that exists is one a run can be
/// attempted from. The Run feature reads it and calls
/// `ReplicaConnector.connect` with the first five fields verbatim; nothing
/// here is an `Agent`, a `Channel` or a `dsync_core` verdict, because the
/// setup page decides nothing about the run itself, only what it is over.
///
/// [remoteRootPath] is carried exactly as typed, `~` and all: it goes over
/// the wire in a `ReplicaSpec` and the desktop expands it in its own
/// environment (SPEC §4.4) — see `RunSetupController` for why the head must
/// not expand it. [addressOverride] is SPEC §4.4's manual re-entry hatch;
/// `null` means the paired device's cached address.
class RunRequest {
  const RunRequest({
    required this.localRootPath,
    required this.deviceName,
    required this.peerDeviceId,
    required this.remoteRootPath,
    required this.addressOverride,
    required this.jobs,
    required this.dryRun,
    this.ignorePatterns = const [],
  });

  /// Side `a`: an absolute path on this device, the folder the user
  /// chose through the platform's folder chooser.
  final String localRootPath;

  /// This device's own name for the peer, what `ReplicaConnector.connect`
  /// resolves through the paired-device store.
  final String deviceName;

  /// The peer's grouped device id — the durable half of the pairing (a name
  /// is renameable), and what the archive is keyed under.
  final String peerDeviceId;

  /// Side `b`, unexpanded.
  final String remoteRootPath;

  final PeerAddress? addressOverride;

  /// Hashing concurrency for the local scan.
  final int jobs;

  /// SPEC §11.2 `--dry-run`: show the plan, apply nothing.
  final bool dryRun;

  /// SPEC §9 `ignore` globs — what this run leaves out, as chosen on the
  /// Filters page and saved on the profile.
  ///
  /// Plain strings, like everything else here: the Run feature compiles
  /// them into the one `RuleSet` it hands `RunController`, which is what
  /// sends them to the far replica (SPEC §9 — the rules come from the
  /// initiating side, and the peer compiles the patterns itself). Carrying
  /// a compiled set through the setup page would put a decision object in
  /// a value type, and would leave two places that could compile the same
  /// patterns differently.
  final List<String> ignorePatterns;
}
