import 'file_status.dart';

/// A path the reconciler will not resolve on its own (SPEC §6). `null`: that
/// side has no record of it.
final class ConflictInfo {
  const ConflictInfo({required this.path, required this.a, required this.b});

  final String path;
  final FileStatus? a;
  final FileStatus? b;
}
