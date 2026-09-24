import 'dart:convert';
import 'dart:io';

import 'app_settings.dart';
import 'atomic_write.dart';

/// The preferences this head keeps for itself (the Settings page's store).
/// Persisted in the core's state directory (SPEC §8.3), beside the
/// paired-device store: the head learns that directory from the core's
/// answer to `init`, so it never writes where an older build kept its
/// state.
///
/// **A head-owned store.** Nothing outside the head reads it — the CLI
/// takes the same decision from `--bind` on the command line — so it lives
/// under `lib/app/` with the rest of the head rather than in the core.
///
/// **Fresh reads** ([load] and [save] each open and parse
/// the file — no copy is held across calls, so the address the Settings
/// page just wrote is the one the next pairing window binds) and **one
/// versioned JSON document, rewritten atomically** via
/// [writeFileAtomically], because a settings document is a handful of values
/// changed by a deliberate human action and the whole-document rewrite
/// costs nothing.
///
/// **Absent vs. damaged.** A missing file is the ordinary first-run case
/// and [load] answers [AppSettings.defaults] for it. A file that exists but
/// does not decode as this store's document throws
/// [AppSettingsStoreCorruptException] instead — damaged bytes lose
/// convenience, not trust, so this surfaces on the Settings page rather
/// than failing the bootstrap, but it must never *read* as the defaults:
/// "I never changed this" and "the file that said what I changed it to
/// cannot be trusted" are different facts, and only the user can act on
/// the second.
class AppSettingsStore {
  /// Bumped when the on-disk document shape changes. A document claiming a
  /// different version is corruption, not a format this store degrades
  /// gracefully from — there is exactly one shape this store has ever
  /// written.
  static const schemaVersion = 1;

  final File _file;

  AppSettingsStore(this._file);

  /// The stored settings, freshly read from disk, or [AppSettings.defaults]
  /// when [_file] does not exist yet.
  Future<AppSettings> load() async {
    if (!await _file.exists()) return AppSettings.defaults;

    final String raw;
    try {
      raw = await _file.readAsString();
    } on FileSystemException catch (e) {
      throw AppSettingsStoreCorruptException(_file.path, e.toString());
    }

    try {
      return _parseDocument(raw);
    } catch (e) {
      // Anything a malformed document can throw while being decoded or
      // shape-checked — a JSON syntax error from a truncated write, a
      // failed cast, a missing key, a bind address that is not an address.
      // All of it is one fact to a caller: this file cannot be trusted, and
      // must not be read as the defaults (see the class doc comment).
      throw AppSettingsStoreCorruptException(_file.path, e.toString());
    }
  }

  /// Rewrites the whole document as exactly [settings], atomically: written
  /// to a scratch file and renamed over [_file] — never a partially-written
  /// document on disk, never two writers racing onto the same final name.
  Future<void> save(AppSettings settings) async {
    final document = {
      'schemaVersion': schemaVersion,
      'network': {'bindAddress': settings.bindAddress.address},
    };
    await writeFileAtomically(_file, jsonEncode(document));
  }

  AppSettings _parseDocument(String raw) {
    final decoded = jsonDecode(raw);
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('top-level document is not a JSON object');
    }
    if (decoded['schemaVersion'] != schemaVersion) {
      throw FormatException(
        'unsupported schema version: ${decoded['schemaVersion']}',
      );
    }
    final network = decoded['network'];
    if (network is! Map<String, dynamic>) {
      throw const FormatException('"network" is not a JSON object');
    }
    final bindAddress = network['bindAddress'];
    if (bindAddress is! String) {
      throw const FormatException('"network.bindAddress" is not a string');
    }
    // The one rule about what a bind address may be, the same one the
    // Settings page refuses a hostname with — not a second copy of it.
    return AppSettings(bindAddress: parseBindAddress(bindAddress));
  }
}

/// Thrown by [AppSettingsStore.load] when its file exists but cannot be
/// read as this store's document: truncated, malformed JSON, or
/// well-formed JSON of the wrong shape, schema version or bind address.
/// Deliberately not treated as the defaults — see the class doc comment on
/// absent vs. damaged.
class AppSettingsStoreCorruptException implements Exception {
  final String path;
  final String detail;

  const AppSettingsStoreCorruptException(this.path, this.detail);

  @override
  String toString() =>
      'Settings file at $path is damaged and cannot be trusted as either '
      'your settings or the defaults ($detail). Remove it to start again '
      'from the defaults, or restore it from a backup.';
}
