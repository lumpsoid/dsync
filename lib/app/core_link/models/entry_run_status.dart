/// Where one entry of a run session stands, as the core decided it.
sealed class EntryRunStatus {
  const EntryRunStatus();
}

final class EntryPending extends EntryRunStatus {
  const EntryPending();
}

final class EntryRunning extends EntryRunStatus {
  const EntryRunning();
}

final class EntrySynced extends EntryRunStatus {
  const EntrySynced();
}

/// Not there to sync; nothing was written. [reason] is the core's line.
final class EntrySkipped extends EntryRunStatus {
  const EntrySkipped(this.reason);

  final String reason;
}

final class EntryFailed extends EntryRunStatus {
  const EntryFailed(this.message);

  final String message;
}

/// Never started: the session was stopped, or an earlier entry found the
/// device unreachable.
final class EntryNotRun extends EntryRunStatus {
  const EntryNotRun();
}
