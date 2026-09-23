/// Where one served `writeFile` is, between its request frame being decoded
/// and its reply being flushed (SPEC §17, task 9a89f7).
///
/// **The stages the code actually has**, in the order a write passes them.
/// There is no separate "storage starts" instant: `AgentServer` calls
/// `LocalAgent.writeFile` the moment it dispatches, and that call opens the
/// file and then writes each chunk as it is taken, so the storage calls start
/// at [awaiting]'s start and interleave with [receiving]. What storage costs
/// once no byte is left to wait for is [storing].
enum WriteStage {
  /// Request decoded, handler not yet started: the frame sat in the router's
  /// queue behind a frame whose route was not taking any.
  queued,

  /// Handler started — `writeFile` called, directory created, file opened —
  /// and no `fileBytes` frame taken yet.
  awaiting,

  /// First `fileBytes` frame taken, terminator not yet: bytes arriving and
  /// being written as they land.
  receiving,

  /// Terminator taken, `writeFile` not yet returned: flush, close, mtime,
  /// mode and stat, with every byte already in hand.
  storing,

  /// `writeFile` returned, reply not yet flushed to the transport.
  replying,
}
