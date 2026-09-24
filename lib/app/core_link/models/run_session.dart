import 'run_update.dart';

/// A run that started: its archive id, its two sides as typed, and its
/// story in [updates], which ends with a [RunEnded].
final class RunSession {
  const RunSession({
    required this.session,
    required this.profileId,
    required this.a,
    required this.b,
    required this.updates,
  });

  final int session;
  final String profileId;
  final String a;
  final String b;
  final Stream<RunUpdate> updates;
}
