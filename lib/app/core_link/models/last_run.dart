/// What a profile's last run left, as its run markers say (SPEC §7.6) —
/// the most pressing of any entry.
enum LastRun {
  /// It finished and holds nothing back.
  settled,

  /// It finished, but a write an earlier run died making is still held
  /// back as a conflict until a run keeps one side's copy.
  writeHeld,

  /// It died mid-apply.
  died,
}
