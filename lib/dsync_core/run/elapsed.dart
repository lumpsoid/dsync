/// Where elapsed time comes from, so a test can drive a measurement with
/// plain values instead of sleeping.
///
/// A monotonic *elapsed* reading rather than a wall clock (`DateTime
/// Function()`, which is what `AppController` and `HumanRenderer` inject for
/// their own purposes): those two format timestamps for a human, where the
/// wall clock is the answer, while every measurement here is a difference
/// between two readings — and a wall clock that steps, over an NTP correction
/// or a phone changing timezone mid-run, makes a difference meaningless or
/// negative.
///
/// In its own file because two unrelated things now need it and neither
/// should have to import the other: `RunMetricsRecorder` times phases and
/// operations, and `RequestWindow` times how long an operation waited for a
/// slot (SPEC §17). The window is pure scheduling and must not depend on the
/// recorder to stay that way.
typedef Elapsed = Duration Function();

/// An [Elapsed] reading from a [Stopwatch] started at this call — the default
/// every measurement uses when no test seam is supplied.
Elapsed stopwatchElapsed() {
  final stopwatch = Stopwatch()..start();
  return () => stopwatch.elapsed;
}
