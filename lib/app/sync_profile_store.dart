import 'dart:convert';
import 'dart:io';

import 'package:dsync/dsync_core/temp_file.dart';

import 'sync_profile.dart';

/// The durable set of runs this head has saved (the home list): each a
/// named [SyncProfile] the user can re-run with no typing. Persisted in the
/// state directory (SPEC §8.3), beside the paired-device store and the
/// archives.
///
/// **A head-owned store, not SPEC §12's profile file** — see
/// `SyncProfile`'s doc comment for why the §12 TOML shape does not fit the
/// head. Because nothing else reads this file, it lives under `lib/app/`
/// with the rest of the head, not in `dsync_core` beside
/// `PairedDeviceStore`; `core` is where a store goes when a second head
/// needs it, and no second head reads head profiles.
///
/// Everything else about the shape is [PairedDeviceStore]'s, deliberately
/// one pattern across the head's two stores: **fresh reads** ([load],
/// [byId], [save] and [delete] each open and parse the file — no copy is
/// held across calls, so a profile saved by one controller is on the home
/// list the moment the next refresh happens) and **one JSON document,
/// rewritten atomically** (a profile set is a handful of entries mutated
/// only by a deliberate human action, so the whole-document rewrite costs
/// nothing and buys the crash-safety of `tempPathFor` plus `File.rename`).
///
/// **Absent vs. damaged**, the same way round: a missing file is the
/// ordinary first-run case and [load] returns `[]` for it, while a file
/// that exists but does not decode as this store's shape throws
/// [SyncProfileStoreCorruptException] rather than reading as empty. An
/// empty list here loses convenience, not trust — unlike the paired-device
/// store, whose empty set is "trust nobody" — so a corrupt profile store
/// surfaces as the home page's error line rather than a failed bootstrap.
/// But damaged bytes must still never *read* as a deliberate empty list,
/// because the difference between "I deleted my profiles" and "this file
/// cannot be trusted" is one the user has to see to act on.
class SyncProfileStore {
  /// Bumped when the on-disk document shape changes; what [_save] writes.
  /// A document claiming a version this store does not know is corruption,
  /// not a format it degrades gracefully from.
  static const schemaVersion = 2;

  /// Every version [load] can read, newest first. Version 1 is version 2
  /// without `ignorePatterns`, and is read as a profile that filters
  /// nothing — which is exactly what it was, since the head had no filters
  /// when it was written. It is migrated on the next save rather than
  /// rewritten on read: a read that rewrote the file would make opening
  /// the home list a write, and there is nothing here that a v1 document
  /// cannot answer.
  static const _readableSchemaVersions = {2, 1};

  final File _file;

  /// Distinguishes this write's scratch file from another write's, per
  /// [tempPathFor]'s own contract, within one running process.
  int _nextTempSequence = 0;

  SyncProfileStore(this._file);

  /// Every saved profile, freshly read from disk, in the order they were
  /// saved — the home list's order. `[]` when [_file] does not exist yet.
  Future<List<SyncProfile>> load() async {
    if (!await _file.exists()) return [];

    final String raw;
    try {
      raw = await _file.readAsString();
    } on FileSystemException catch (e) {
      throw SyncProfileStoreCorruptException(_file.path, e.toString());
    }

    try {
      return _parseDocument(raw);
    } on SyncProfileStoreCorruptException {
      rethrow;
    } catch (e) {
      // Anything else a malformed document can throw while being decoded or
      // shape-checked — a JSON syntax error from a truncated write, a failed
      // cast, a missing key. All of it is the same fact from a caller's
      // point of view: this file cannot be trusted, and must not be read as
      // an empty list (see the class doc comment).
      throw SyncProfileStoreCorruptException(_file.path, e.toString());
    }
  }

  /// The profile saved under [id], or `null` if none is — what the home
  /// page hands Run setup, and Run setup re-reads, so the destination loads
  /// what it needs from an id.
  Future<SyncProfile?> byId(String id) async {
    for (final profile in await load()) {
      if (profile.id == id) return profile;
    }
    return null;
  }

  /// Saves [profile], replacing any profile already stored under its id —
  /// an edit to an existing profile is a save over the same id, and a
  /// one-off run given a name saves beside the others. Deliberately an
  /// upsert rather than an `add` with a collision rule: the id is a
  /// derivation over the profile's own fields, so "same id" *is* "same
  /// sync relationship", and the newer form of it should win.
  Future<void> save(SyncProfile profile) async {
    final profiles = await load();
    final index = profiles.indexWhere((p) => p.id == profile.id);
    if (index == -1) {
      await _save([...profiles, profile]);
    } else {
      final replaced = [...profiles];
      replaced[index] = profile;
      await _save(replaced);
    }
  }

  /// Removes the profile saved under [id]. Throws
  /// [SyncProfileNotFoundException] if none is there, the same as
  /// [PairedDeviceStore.revoke] does for a device — a caller asking to
  /// delete a specific profile should be told when it was never there,
  /// even though the refresh that follows makes the row disappear either
  /// way.
  Future<void> delete(String id) async {
    final profiles = await load();
    final remaining = profiles.where((p) => p.id != id).toList();
    if (remaining.length == profiles.length) {
      throw SyncProfileNotFoundException(id);
    }
    await _save(remaining);
  }

  List<SyncProfile> _parseDocument(String raw) {
    final decoded = jsonDecode(raw);
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('top-level document is not a JSON object');
    }
    if (!_readableSchemaVersions.contains(decoded['schemaVersion'])) {
      throw FormatException(
        'unsupported schema version: ${decoded['schemaVersion']}',
      );
    }
    final profiles = decoded['profiles'];
    if (profiles is! List) {
      throw const FormatException('"profiles" is not a list');
    }
    return [for (final entry in profiles) _profileFromJson(entry)];
  }

  SyncProfile _profileFromJson(Object? entry) {
    if (entry is! Map<String, dynamic>) {
      throw const FormatException('profile entry is not a JSON object');
    }
    return SyncProfile(
      id: entry['id'] as String,
      name: entry['name'] as String,
      localRootPath: entry['localRootPath'] as String,
      peerDeviceId: entry['peerDeviceId'] as String,
      remoteRootPath: entry['remoteRootPath'] as String,
      jobs: entry['jobs'] as int,
      // Absent in a v1 document, and absent in a v2 one written before
      // this profile was ever filtered.
      ignorePatterns: [
        for (final pattern in entry['ignorePatterns'] as List? ?? const [])
          pattern as String,
      ],
    );
  }

  Map<String, Object?> _profileToJson(SyncProfile profile) => {
    'id': profile.id,
    'name': profile.name,
    'localRootPath': profile.localRootPath,
    'peerDeviceId': profile.peerDeviceId,
    'remoteRootPath': profile.remoteRootPath,
    'jobs': profile.jobs,
    'ignorePatterns': profile.ignorePatterns,
  };

  /// Rewrites the whole document with exactly [profiles] and no others,
  /// atomically: written to a scratch file and renamed over [_file], the
  /// same pattern `PairedDeviceStore._save` runs — never a partially-written
  /// document on disk, never two writers racing onto the same final name.
  Future<void> _save(List<SyncProfile> profiles) async {
    final document = {
      'schemaVersion': schemaVersion,
      'profiles': [for (final profile in profiles) _profileToJson(profile)],
    };
    await _file.parent.create(recursive: true);
    final temp = File(tempPathFor(_file.path, _nextTempSequence++));
    try {
      // flush: true is fsync: the replacement has to be on disk before the
      // rename swaps it in, or a crash in that window loses the whole store.
      await temp.writeAsString(jsonEncode(document), flush: true);
      await temp.rename(_file.path);
    } catch (_) {
      if (await temp.exists()) await temp.delete();
      rethrow;
    }
  }
}

/// Thrown by [SyncProfileStore.load] when its file exists but cannot be
/// read as this store's document: truncated, malformed JSON, or
/// well-formed JSON of the wrong shape or schema version. Deliberately not
/// treated as an empty list — see the class doc comment on absent vs.
/// damaged.
class SyncProfileStoreCorruptException implements Exception {
  final String path;
  final String detail;

  const SyncProfileStoreCorruptException(this.path, this.detail);

  @override
  String toString() =>
      'Saved-profile store at $path is corrupt and cannot be trusted as '
      'either the current set of saved profiles or an empty one. Restore it '
      'from a backup, or remove it — the profiles are re-savable, but they '
      'are not coming back from a damaged file.';
}

/// Thrown by [SyncProfileStore.delete] when no profile matches the given
/// id.
class SyncProfileNotFoundException implements Exception {
  final String id;

  const SyncProfileNotFoundException(this.id);

  @override
  String toString() => 'No saved profile with id $id';
}
