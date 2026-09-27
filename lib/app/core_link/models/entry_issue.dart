/// An entry of a finished session that did not sync: its place in the
/// session's entries, and the core's line saying why.
final class EntryIssue {
  const EntryIssue({required this.index, required this.reason});

  final int index;
  final String reason;
}
