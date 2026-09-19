/// What one replica's `writeFile` has actually spent, step by step, over a
/// whole session (SPEC §17).
///
/// **Because `far` minus `starved` is one number for eight syscalls.** A
/// `writeFile` on the receiving end creates the parent directory, opens a
/// temporary file, writes it, closes it, stamps an mtime, chmods, renames,
/// and stats. Those have wildly different fixes — the directory create is
/// removable outright, the `chmod` was a process spawn until it became a
/// syscall, the rename is neither — and until they are separated the only
/// honest thing to say about the destination's cost is its total.
///
/// **Cumulative, and reported once.** Every figure here is a session total
/// rather than a per-call split, for the reason [FarSideReport.sendWait] is:
/// the alternative is seven more integers on all 14,000 replies, which would
/// measurably inflate the byte counts this report exists to explain. The
/// totals are sent on the `unlock` reply, the last exchange of a run, so a
/// run that dies before unlocking reports nothing rather than a partial
/// figure that reads like a complete one.
///
/// **They sum past the clock, and are meant to.** Several `writeFile`s are
/// served at once, so these overlap each other exactly as [FarSideReport.span]
/// does. Divide by [files] to get what one file cost, and read the steps
/// against each other rather than against the phase.
class WritePathStats {
  /// How many `writeFile` calls contributed — the denominator for every
  /// duration here.
  final int files;

  /// `Directory.create(recursive: true)` on the destination's parent, paid
  /// per file even when the directory has existed since the first one.
  final Duration create;

  /// Opening the temporary file, writing every chunk, flushing and closing.
  ///
  /// **Contains the wait for the bytes**, which is why it is not the
  /// destination's own cost: the frames arrive at the link's pace and this
  /// step consumes them as they land. `FarSideReport.inboundWait` is that
  /// wait, measured separately, and the difference is what writing actually
  /// cost. Note that this is not an fsync — `IOSink.flush` drains the buffer
  /// to the descriptor, and the only fsync in the write path belongs to the
  /// archive store, one per batch (SPEC §8.2).
  final Duration write;

  /// `setLastModified` on the temporary file (SPEC §7.4).
  final Duration mtime;

  /// Applying the intended mode — one `chmod(2)` through `dart:ffi`, taken
  /// unconditionally (SPEC §7.4).
  final Duration mode;

  /// How many `chmod` processes were actually started.
  ///
  /// The figure that said whether the mode step was a stat or a fork, back
  /// when it could be either. It answered "a fork, every time": 14,471
  /// spawns for 14,471 files, because a fresh temporary file carries the
  /// umask's mode and not the source's, so the stat that guarded the spawn
  /// never hit. Both are gone — the step is a syscall now — so this is zero
  /// by construction and stays only until the run that confirms it has been
  /// read (task 9d2158 §10.1).
  final int chmodSpawns;

  /// Renaming the temporary file over the destination (SPEC §7.2).
  final Duration rename;

  /// The final `stat` of the destination, which is what the reply carries
  /// back and the archive records (SPEC §7.4).
  final Duration stat;

  const WritePathStats({
    this.files = 0,
    this.create = Duration.zero,
    this.write = Duration.zero,
    this.mtime = Duration.zero,
    this.mode = Duration.zero,
    this.chmodSpawns = 0,
    this.rename = Duration.zero,
    this.stat = Duration.zero,
  });

  /// Every step summed — what one `writeFile` costs this side end to end,
  /// before the reply is built.
  Duration get total => create + write + mtime + mode + rename + stat;

  /// This plus one more file's steps.
  WritePathStats plus({
    required Duration create,
    required Duration write,
    required Duration mtime,
    required Duration mode,
    required int chmodSpawns,
    required Duration rename,
    required Duration stat,
  }) => WritePathStats(
    files: files + 1,
    create: this.create + create,
    write: this.write + write,
    mtime: this.mtime + mtime,
    mode: this.mode + mode,
    chmodSpawns: this.chmodSpawns + chmodSpawns,
    rename: this.rename + rename,
    stat: this.stat + stat,
  );
}
