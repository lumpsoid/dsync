import 'dart:io';

/// What the head's Settings page owns: the preferences this installation
/// keeps for itself, as already-parsed values.
///
/// One setting so far — [bindAddress] — and deliberately a model rather
/// than a bare [InternetAddress] threaded around, because the thing the
/// Settings page edits and [AppSettingsStore] writes is "the settings",
/// and a document with one field today is the same document with two
/// tomorrow.
///
/// **Parsed, not textual.** A bind address that reached here as a string
/// would be re-validated by everything that read it; `parseBindAddress` is
/// the one rule (`lib/dsync_core/models/host_port.dart`), it runs where the
/// value is constructed — at the page's field and at the store's parse —
/// and nothing downstream re-decides whether a hostname is acceptable.
class AppSettings {
  const AppSettings({required this.bindAddress});

  /// Which address the pairing listener binds — the head's equivalent of
  /// `dsync pair show --bind` (task 2b26ac). A literal only, never a
  /// hostname; see `parseBindAddress` for why.
  final InternetAddress bindAddress;

  /// What an installation that has never opened Settings runs with:
  /// `0.0.0.0`, the same default the CLI's `--bind` carries, so both heads
  /// listen in the same place until somebody says otherwise.
  static final AppSettings defaults = AppSettings(
    bindAddress: InternetAddress.anyIPv4,
  );
}
