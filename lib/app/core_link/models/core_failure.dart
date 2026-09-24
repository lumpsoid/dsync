/// A command the core refused or could not carry out; [message] is the
/// core's own words, ready to show.
final class CoreFailure implements Exception {
  const CoreFailure(this.message);

  final String message;

  @override
  String toString() => message;
}
