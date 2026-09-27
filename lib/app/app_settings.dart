import 'dart:io';

import 'theme_preference.dart';

/// What the head's Settings page owns: the preferences this installation
/// keeps for itself, as already-parsed values.
///
/// Three settings — [bindAddress], [theme] and [keepScreenAwake] — held as
/// one model because the thing the Settings page edits and
/// [AppSettingsStore] writes is "the settings", one whole document:
/// changing one of them is [withBindAddress], [withTheme] or
/// [withKeepScreenAwake] on what is stored, so a save never drops the
/// others.
///
/// **Parsed, not textual.** A bind address that reached here as a string
/// would be re-validated by everything that read it; [parseBindAddress] is
/// the head's one rule for it, it runs where the value is constructed — at
/// the page's field and at the store's parse — and nothing downstream
/// re-decides whether a hostname is acceptable. (The core parses the
/// literal again when it binds; this copy is what lets the Settings page
/// refuse a hostname before it is saved.)
class AppSettings {
  const AppSettings({
    required this.bindAddress,
    required this.theme,
    required this.keepScreenAwake,
  });

  /// Which address the pairing listener binds — the head's equivalent of
  /// `dsync pair show --bind` (task 2b26ac). A literal only, never a
  /// hostname; see `parseBindAddress` for why.
  final InternetAddress bindAddress;

  /// Which brightness the app draws in.
  final ThemePreference theme;

  /// Whether a live run and a serving session hold the screen awake
  /// (`ScreenWake`).
  final bool keepScreenAwake;

  /// These settings with the bind address changed to [address].
  AppSettings withBindAddress(InternetAddress address) => AppSettings(
    bindAddress: address,
    theme: theme,
    keepScreenAwake: keepScreenAwake,
  );

  /// These settings with the theme changed to [preference].
  AppSettings withTheme(ThemePreference preference) => AppSettings(
    bindAddress: bindAddress,
    theme: preference,
    keepScreenAwake: keepScreenAwake,
  );

  /// These settings with keeping the screen awake turned [on] or off.
  AppSettings withKeepScreenAwake(bool on) =>
      AppSettings(bindAddress: bindAddress, theme: theme, keepScreenAwake: on);

  /// What an installation that has never opened Settings runs with:
  /// `0.0.0.0`, the same default the CLI's `--bind` carries, so both heads
  /// listen in the same place until somebody says otherwise; the device's
  /// own light or dark; and the screen held awake while a run or serve is
  /// live, as it was before this was a setting.
  static final AppSettings defaults = AppSettings(
    bindAddress: InternetAddress.anyIPv4,
    theme: ThemePreference.system,
    keepScreenAwake: true,
  );
}

/// The port a serving device answers on unless told otherwise, and the one
/// a pairing code names for the device's sync service (SPEC §4.4) - the
/// CLI's `--port` default.
const defaultPeerPort = 28771;

/// A bind address as the user typed it: an IP literal (brackets around an
/// IPv6 one allowed), never a hostname. Throws [FormatException] saying
/// what to type instead.
InternetAddress parseBindAddress(String text) {
  final trimmed = text.trim();
  final bare = trimmed.startsWith('[') && trimmed.endsWith(']')
      ? trimmed.substring(1, trimmed.length - 1)
      : trimmed;
  final address = InternetAddress.tryParse(bare);
  if (address == null) {
    throw FormatException(
      '"$text" is not an IP address. Give an address literal this machine '
      'has — 0.0.0.0 for every IPv4 interface, :: for every interface of '
      'either family, or one interface\'s own address — not a hostname.',
    );
  }
  return address;
}

/// Whether [address] is a wildcard — `0.0.0.0` or `::`, "every interface":
/// it says where this host listens, not where a peer should dial.
bool isWildcardAddress(InternetAddress address) =>
    address.address == InternetAddress.anyIPv4.address ||
    address.address == InternetAddress.anyIPv6.address;
