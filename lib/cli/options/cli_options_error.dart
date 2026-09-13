/// An invocation that violates one of the fatal argument rules SPEC §11.5
/// lists ("fatal: bad arguments") — e.g. `--verbose` with `--quiet`, or a
/// mixed ad-hoc pair with the remote location first.
///
/// Thrown by [CliOptions]'s constructor and by the `SyncTarget` factories it
/// calls into (`lib/cli/options/sync_target.dart`), so every rule lives with
/// the value it is about rather than in a `Command`. Caught in
/// `lib/cli/commands/`, where [message] is handed to `Command.usageException`
/// — `runDsyncCli` already maps the resulting `UsageException` to exit code
/// 3.
class CliOptionsError implements Exception {
  final String message;

  const CliOptionsError(this.message);

  @override
  String toString() => message;
}
