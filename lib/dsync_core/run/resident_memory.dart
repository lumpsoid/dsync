import 'dart:io';

/// This process's resident set as two numbers: what it holds at the reading,
/// and the most it has held since it started.
///
/// [peak] is a high-water mark the kernel keeps, not a sample — which is the
/// whole reason it is worth reading. A run's transient buffer is megabytes
/// against a Flutter process's tens, and a poller that woke every 200 ms
/// would miss it; this cannot.
typedef ResidentBytes = ({int current, int peak});

/// Where those two numbers come from, so a test can drive a measurement with
/// plain values instead of allocating, the way `Elapsed` is the seam for time.
typedef ResidentMemory = ResidentBytes Function();

/// The real reading, from `dart:io` — the default when no test seam is
/// supplied.
///
/// `ProcessInfo.maxRss` is the process's lifetime high water, so on a head
/// that was open before the run it includes whatever that head peaked at
/// earlier; `currentRss` taken at the top of the run is what makes the run's
/// own share readable. Both platforms this matters on — Linux and Android —
/// report it; a platform that does not gives 0, which is why
/// `RunMetricsRecorder` treats zero as "not measured" rather than as a
/// figure.
ResidentMemory processResidentMemory() =>
    () => (current: ProcessInfo.currentRss, peak: ProcessInfo.maxRss);
