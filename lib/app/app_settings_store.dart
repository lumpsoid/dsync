import 'dart:convert';
import 'dart:io';

import 'app_settings.dart';
import 'atomic_write.dart';
import 'peer_port.dart';
import 'theme_preference.dart';

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
///
/// **Versioned like the core's formats** (SPEC §8.4): the document carries
/// `version: "major.minor"`. Another major is refused with
/// [AppSettingsStoreForeignVersionException], naming both versions; a later
/// minor of this major is read, and the fields this build does not know are
/// ignored.
///
/// **1.1 added `appearance.theme`.** A document without the `appearance`
/// section — every 1.0 one — reads as [ThemePreference.system], the
/// default it was drawn in; a present one naming no known theme is damage
/// like any other wrong shape.
///
/// **1.2 added `power.keepScreenAwake`.** A document without the `power`
/// section — every 1.0 and 1.1 one — reads as on, the screen held awake as
/// it always was; a present one that is not a boolean is damage.
///
/// **1.3 added `network.peerPort`.** A document without it — every 1.0 to
/// 1.2 one — reads as [defaultPeerPort], the port this head always served
/// on; a present one that is not a whole number from 1 to 65535 is damage.
class AppSettingsStore {
  /// The version this build writes, `major.minor`.
  static const formatVersion = '1.3';

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
    } on AppSettingsStoreForeignVersionException {
      rethrow;
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
      'version': formatVersion,
      'network': {
        'bindAddress': settings.bindAddress.address,
        'peerPort': settings.peerPort.value,
      },
      'appearance': {'theme': settings.theme.name},
      'power': {'keepScreenAwake': settings.keepScreenAwake},
    };
    await writeFileAtomically(_file, jsonEncode(document));
  }

  AppSettings _parseDocument(String raw) {
    final decoded = jsonDecode(raw);
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('top-level document is not a JSON object');
    }
    final version = decoded['version'];
    if (version is! String) {
      throw const FormatException('"version" is not a string');
    }
    if (_majorOf(version) != _majorOf(formatVersion)) {
      throw AppSettingsStoreForeignVersionException(_file.path, version);
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
    return AppSettings(
      bindAddress: parseBindAddress(bindAddress),
      peerPort: _parsePeerPort(network),
      theme: _parseTheme(decoded['appearance']),
      keepScreenAwake: _parseKeepScreenAwake(decoded['power']),
    );
  }

  /// The `network` section's peer port: [defaultPeerPort] when it is absent
  /// (a 1.0 to 1.2 document), a port [PeerPort] accepts when it is present.
  static PeerPort _parsePeerPort(Map<String, dynamic> network) {
    if (!network.containsKey('peerPort')) return PeerPort(defaultPeerPort);
    final peerPort = network['peerPort'];
    if (peerPort is! int) {
      throw const FormatException('"network.peerPort" is not a whole number');
    }
    return PeerPort(peerPort);
  }

  /// The `power` section's keep-awake switch: on when the section is
  /// absent (a 1.0 or 1.1 document), a boolean when it is present.
  static bool _parseKeepScreenAwake(Object? power) {
    if (power == null) return true;
    if (power is! Map<String, dynamic>) {
      throw const FormatException('"power" is not a JSON object');
    }
    final keepScreenAwake = power['keepScreenAwake'];
    if (keepScreenAwake is! bool) {
      throw const FormatException('"power.keepScreenAwake" is not a boolean');
    }
    return keepScreenAwake;
  }

  /// The `appearance` section's theme: [ThemePreference.system] when the
  /// section is absent (a 1.0 document), a known name when it is present.
  static ThemePreference _parseTheme(Object? appearance) {
    if (appearance == null) return ThemePreference.system;
    if (appearance is! Map<String, dynamic>) {
      throw const FormatException('"appearance" is not a JSON object');
    }
    final theme = appearance['theme'];
    for (final preference in ThemePreference.values) {
      if (preference.name == theme) return preference;
    }
    throw FormatException('"appearance.theme" is not a known theme: $theme');
  }

  /// The major of a `major.minor` version, both plain decimal digits.
  static int _majorOf(String version) {
    if (!RegExp(r'^\d+\.\d+$').hasMatch(version)) {
      throw FormatException(
        '"$version" is not a version; expected major.minor, like 1.0',
      );
    }
    return int.parse(version.split('.').first);
  }
}

/// Why [AppSettingsStore.load] could not answer the stored settings. Either
/// way the file is not read as the defaults — see the class doc comment on
/// absent vs. damaged.
sealed class AppSettingsStoreException implements Exception {
  const AppSettingsStoreException();
}

/// Thrown by [AppSettingsStore.load] when its file exists but cannot be
/// read as this store's document: truncated, malformed JSON, or
/// well-formed JSON of the wrong shape, version text, bind address, peer
/// port, theme or keep-awake switch.
class AppSettingsStoreCorruptException extends AppSettingsStoreException {
  final String path;
  final String detail;

  const AppSettingsStoreCorruptException(this.path, this.detail);

  @override
  String toString() =>
      'Settings file at $path is damaged and cannot be trusted as either '
      'your settings or the defaults ($detail). Remove it to start again '
      'from the defaults, or restore it from a backup.';
}

/// Thrown by [AppSettingsStore.load] when its file is well-formed but
/// written in another major of the format, which this build cannot read.
class AppSettingsStoreForeignVersionException
    extends AppSettingsStoreException {
  final String path;
  final String found;

  const AppSettingsStoreForeignVersionException(this.path, this.found);

  @override
  String toString() =>
      'Settings file at $path is format $found, which this build (format '
      '${AppSettingsStore.formatVersion}) cannot read. Use a dsync that reads '
      'format ${found.split('.').first}.x, or remove it to start again from '
      'the defaults.';
}
