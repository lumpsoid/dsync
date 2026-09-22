import 'dart:io';

import 'package:dsync/dsync_core/state_dir.dart';

/// Whether a profile's last run finished its apply (SPEC §7.6), as one empty
/// file in the initiating host's state directory.
///
/// `RunController` creates it before the apply writes anything and deletes it
/// when the apply returns, failed actions or not: those surface on the next
/// run as conflicts labelled interrupted. A marker still there means the
/// process died or the run aborted mid-apply. It is a file of its own rather
/// than something read out of the archive log so that asking "did the last
/// run finish?" costs one stat per profile, not a replay of every log.
class RunMarker {
  final File _file;

  RunMarker(this._file);

  /// The standard marker for [profileId] (SPEC §8.3):
  /// `<state dir>/<profileId>.run`. [platform] is required for the reason
  /// `resolveLockPath` gives.
  factory RunMarker.forProfile({
    required String profileId,
    Map<String, String> environment = const {},
    required StateDirPlatform platform,
  }) => RunMarker(
    File('${resolveStateDir(environment, platform)}/$profileId.run'),
  );

  /// Whether a run of this profile started an apply and never finished it.
  Future<bool> isPresent() => _file.exists();

  /// Flushed, so a process killed right after this still leaves it.
  Future<void> create() async {
    await _file.parent.create(recursive: true);
    await _file.writeAsBytes(const [], flush: true);
  }

  Future<void> delete() async {
    if (await _file.exists()) await _file.delete();
  }
}
