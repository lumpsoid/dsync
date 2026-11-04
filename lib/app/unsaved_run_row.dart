import 'core_link/models/last_run.dart';
import 'core_link/models/profile_entry.dart';

/// A run no saved profile claims, as the home list warns of it: a run
/// started without saving it was killed mid-apply, or finished with a dead
/// run's write still held back (task 75af93). Without this there would be
/// no trace of it at all — a saved profile's row carries its own warning,
/// but a draft has no row. Every field is the text a widget puts on screen.
class UnsavedRunRow {
  const UnsavedRunRow({
    required this.entryId,
    required this.title,
    required this.warning,
  });

  factory UnsavedRunRow.render(UnsavedRun run) => UnsavedRunRow(
    entryId: run.entryId,
    title: switch (run.pair) {
      final pair? => '${pair.a} ↔ ${pair.b}',
      null => 'A run whose folders are not known',
    },
    warning: switch (run.lastRun) {
      // There is a marker, so a settled one is not listed; read as the
      // more pressing of the two rather than as nothing.
      LastRun.died || LastRun.settled =>
        'A run you did not save did not finish. Start a run over the same '
            'folders to sort out the files it left.',
      LastRun.writeHeld =>
        'A write an interrupted run you did not save was making is still '
            'held back. Start a run over the same folders to choose which '
            "side's copy to keep.",
    },
  );

  /// The id the core derives from the run's two sides: what tells two rows
  /// apart.
  final String entryId;

  /// The run's two sides, or what stands in for them.
  final String title;
  final String warning;
}
