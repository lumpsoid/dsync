import 'file_status.dart';

/// A path the reconciler will not resolve on its own (SPEC §6). `null`: that
/// side has no record of it. [interrupted]: a side holds an uncommitted
/// write.
final class ConflictInfo {
  const ConflictInfo({
    required this.path,
    required this.a,
    required this.b,
    required this.interrupted,
  });

  final String path;
  final FileStatus? a;
  final FileStatus? b;
  final bool interrupted;
}
