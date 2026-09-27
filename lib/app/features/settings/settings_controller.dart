import 'dart:io';

import '../../app_controller.dart';
import '../../app_settings.dart';
import '../../app_settings_store.dart';
import '../../mass_delete_guard.dart';
import '../../peer_port.dart';
import '../../theme_preference.dart';
import '../../warn_size.dart';
import 'settings_view_state.dart';

/// Input methods of the Settings page: read what is stored, and store what
/// the user typed or chose.
///
/// Takes the [AppController] it borrows the settings store from as a
/// constructor argument, per the controller role in `app_scope.dart`.
///
/// **The bind-address rule is `parseBindAddress`'s, not this class's.** A
/// literal only, never a hostname — see that function for why — so what
/// happens here is calling it and turning its refusal into the line the
/// page shows. There is no second copy of the rule in the page's field, in
/// this controller, or in `AppSettingsStore`, which parses the stored
/// string through the same call.
///
/// Fetching does not decide and deciding does not fetch: the text is parsed
/// before the store is opened, so a hostname never reaches disk and a write
/// that is attempted is a write of a value already known to be valid.
class SettingsController {
  SettingsController(this.app);

  final AppController app;

  /// The view state this controller renders into; owned here, disposed here.
  final SettingsViewState state = SettingsViewState();

  /// Reads the stored settings onto [state] — what the page asks for on
  /// mounting, and a fresh read every time, per `AppSettingsStore`.
  ///
  /// A damaged file leaves [SettingsViewState.settings] `null` and shows
  /// the store's own line: the defaults must not be displayed as though the
  /// file had said them (see `AppSettingsStore`'s absent-vs-damaged rule),
  /// and the remedy — remove the file, or restore it — is in that line.
  Future<void> load() async {
    try {
      state.recordSettings(await (await app.settings).load());
      state.recordOutcome(const SettingsIdle());
    } on AppSettingsStoreException catch (e) {
      state.recordOutcome(SettingsFailed(e.toString()));
    }
  }

  /// Stores [text] as the pairing listener's bind address, refusing
  /// anything `parseBindAddress` refuses.
  Future<void> saveBindAddress(String text) async {
    final InternetAddress address;
    try {
      address = parseBindAddress(text);
    } on FormatException catch (e) {
      state.recordOutcome(SettingsFailed(e.message));
      return;
    }

    state.recordOutcome(const SettingsWorking());
    final failure = await _change(
      (settings) => settings.withBindAddress(address),
      unchanged: 'The bind address is unchanged.',
    );
    if (failure != null) {
      state.recordOutcome(SettingsFailed(failure));
      return;
    }
    state.recordOutcome(SettingsSaved(_saved(address)));
  }

  /// Stores [text] as the port this device serves on and its pairing codes
  /// name, refusing anything `PeerPort.parse` refuses.
  Future<void> savePeerPort(String text) async {
    final PeerPort port;
    try {
      port = PeerPort.parse(text);
    } on FormatException catch (e) {
      state.recordOutcome(SettingsFailed(e.message));
      return;
    }

    state.recordOutcome(const SettingsWorking());
    final failure = await _change(
      (settings) => settings.withPeerPort(port),
      unchanged: 'The peer port is unchanged.',
    );
    if (failure != null) {
      state.recordOutcome(SettingsFailed(failure));
      return;
    }
    state.recordOutcome(
      SettingsSaved(
        'This device serves on port $port from the next time it serves, and '
        'the next pairing code it shows tells the other device to dial it '
        'there. Devices already paired still dial the port they recorded.',
      ),
    );
  }

  /// Stores [text] as the size a run's plan review warns above when its
  /// profile sets none, refusing anything `WarnSize.parse` refuses; empty
  /// turns the warning off.
  Future<void> saveWarnSize(String text) async {
    final WarnSize size;
    try {
      size = WarnSize.parse(text);
    } on FormatException catch (e) {
      state.recordOutcome(SettingsFailed(e.message));
      return;
    }

    state.recordOutcome(const SettingsWorking());
    final failure = await _change(
      (settings) => settings.withWarnSize(size),
      unchanged: 'The warn size is unchanged.',
    );
    if (failure != null) {
      state.recordOutcome(SettingsFailed(failure));
      return;
    }
    state.recordOutcome(
      SettingsSaved(switch (size) {
        WarnSizeOff() =>
          'A sync warns about its size only when its profile sets one.',
        final WarnSizeAbove size =>
          'From the next sync, a plan that moves more than '
              '${size.label} warns before you apply it, unless its '
              'profile sets a size of its own.',
      }),
    );
  }

  /// Stores [text] as how many files a sync deletes on one side before it
  /// may stop to ask, refusing anything `MassDeleteGuard.parseMinFiles`
  /// refuses. The percent is kept.
  Future<void> saveMassDeleteMinFiles(String text) async {
    final int count;
    try {
      count = MassDeleteGuard.parseMinFiles(text);
    } on FormatException catch (e) {
      state.recordOutcome(SettingsFailed(e.message));
      return;
    }
    await _saveMassDeleteGuard(
      (guard) => guard.withMinFiles(count),
      unchanged: 'The file count is unchanged.',
    );
  }

  /// Stores [text] as the share of a side a sync deletes before it may
  /// stop to ask, refusing anything `MassDeleteGuard.parsePercent` refuses.
  /// The file count is kept.
  Future<void> saveMassDeletePercent(String text) async {
    final int share;
    try {
      share = MassDeleteGuard.parsePercent(text);
    } on FormatException catch (e) {
      state.recordOutcome(SettingsFailed(e.message));
      return;
    }
    await _saveMassDeleteGuard(
      (guard) => guard.withPercent(share),
      unchanged: 'The percent is unchanged.',
    );
  }

  Future<void> _saveMassDeleteGuard(
    MassDeleteGuard Function(MassDeleteGuard guard) change, {
    required String unchanged,
  }) async {
    state.recordOutcome(const SettingsWorking());
    final failure = await _change(
      (settings) =>
          settings.withMassDeleteGuard(change(settings.massDeleteGuard)),
      unchanged: unchanged,
    );
    if (failure != null) {
      state.recordOutcome(SettingsFailed(failure));
      return;
    }
    state.recordOutcome(
      const SettingsSaved(
        'From the next sync, it stops to ask before deleting at these '
        'thresholds. Nothing is deleted past them without your say-so.',
      ),
    );
  }

  /// Stores [theme] and has the app draw in it at once. No line says so:
  /// the page changing colour under the user's finger is the confirmation.
  Future<void> saveTheme(ThemePreference theme) async {
    state.recordOutcome(const SettingsWorking());
    final failure = await _change(
      (settings) => settings.withTheme(theme),
      unchanged: 'The theme is unchanged.',
    );
    if (failure != null) {
      state.recordOutcome(SettingsFailed(failure));
      return;
    }
    app.themeSaved(theme);
    state.recordOutcome(const SettingsIdle());
  }

  /// Stores whether a live run and a serving session hold the screen
  /// awake. Like the theme, the switch moving is the confirmation; the next
  /// run or serve reads it when it starts.
  Future<void> saveKeepScreenAwake(bool on) async {
    state.recordOutcome(const SettingsWorking());
    final failure = await _change(
      (settings) => settings.withKeepScreenAwake(on),
      unchanged: 'Keeping the screen awake is unchanged.',
    );
    if (failure != null) {
      state.recordOutcome(SettingsFailed(failure));
      return;
    }
    state.recordOutcome(const SettingsIdle());
  }

  /// Rewrites the stored settings as [change] of what is stored now, so one
  /// setting's save keeps the others, and records what was written onto
  /// [state]. Returns `null` on success, or the line to show, ending in
  /// [unchanged].
  Future<String?> _change(
    AppSettings Function(AppSettings settings) change, {
    required String unchanged,
  }) async {
    try {
      final store = await app.settings;
      final changed = change(await store.load());
      await store.save(changed);
      state.recordSettings(changed);
    } on AppSettingsStoreException catch (e) {
      return '$e';
    } on FileSystemException catch (e) {
      return 'This device could not save its settings: ${e.message}. '
          '$unchanged';
    }
    return null;
  }

  void dispose() => state.dispose();
}

/// What a stored bind address means, in the user's words: when it takes
/// effect, and — for a wildcard — that the code this device shows will
/// still have to guess which of its addresses to advertise
/// (`chosenAdvertisableHost`).
String _saved(InternetAddress address) {
  final when =
      'The next pairing code this device shows is offered on '
      '${address.address}.';
  return isWildcardAddress(address)
      ? '$when Listening on every interface, so the code advertises this '
            'device\'s best guess at an address the other device can reach.'
      : '$when The code advertises that address, so the other device dials '
            'exactly it.';
}
