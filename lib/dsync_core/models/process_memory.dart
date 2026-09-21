/// What the device the run happened on actually held (SPEC §17).
///
/// **Why the process figure is here at all**, next to counters that measure
/// each buffer exactly: the counters say whether a stated bound held, and
/// this says whether the process survived. They answer different questions
/// and neither substitutes for the other — a read-ahead inside its 1 MiB
/// budget on a phone whose resident set grew 300 MiB is a passing bound and
/// a failing run.
///
/// **Read [growth], not [peakRss], against a buffer's bound.** [peakRss] is
/// the kernel's high water for the whole process lifetime, so on the Flutter
/// head it includes the UI, the graphics memory and anything the app peaked
/// at before the run began. [baselineRss] is what it held when the run's
/// clock started, and the difference is an *upper bound* on the run's own
/// share: it is the run's if nothing else allocated meanwhile, and it
/// overstates otherwise. Cold-starting the head before a measured run is
/// what makes the two figures nearly the same reading.
class ProcessMemory {
  /// Resident bytes when the recorder was built — the top of the run.
  final int baselineRss;

  /// The most resident bytes this process has held, as of the snapshot.
  final int peakRss;

  const ProcessMemory({required this.baselineRss, required this.peakRss});

  /// How much the peak stands above where the run started, never negative —
  /// the kernel's high water cannot fall below a reading taken under it.
  int get growth => peakRss - baselineRss;
}
