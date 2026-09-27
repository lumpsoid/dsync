import 'entry_run_status.dart';
import 'root_kind.dart';

/// One entry of a run session, as the core listed it: its two roots and
/// how it went.
final class EntryRun {
  const EntryRun({
    required this.kind,
    required this.localRoot,
    required this.remoteRoot,
    required this.status,
  });

  final RootKind kind;

  /// This device's side: the folder, or for a file entry the file itself.
  final String localRoot;

  /// The paired device's side, unexpanded.
  final String remoteRoot;
  final EntryRunStatus status;
}
