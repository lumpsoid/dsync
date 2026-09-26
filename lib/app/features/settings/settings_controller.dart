import 'dart:io';

import '../../app_controller.dart';
import '../../app_settings.dart';
import '../../app_settings_store.dart';
import 'settings_view_state.dart';

/// Input methods of the Settings page: read what is stored, and store what
/// the user typed.
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
  /// A damaged file leaves [SettingsViewState.bindAddress] `null` and shows
  /// the store's own line: the defaults must not be displayed as though the
  /// file had said them (see `AppSettingsStore`'s absent-vs-damaged rule),
  /// and the remedy — remove the file, or restore it — is in that line.
  Future<void> load() async {
    try {
      final settings = await (await app.settings).load();
      state.recordBindAddress(settings.bindAddress.address);
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
    try {
      await (await app.settings).save(AppSettings(bindAddress: address));
    } on FileSystemException catch (e) {
      state.recordOutcome(
        SettingsFailed(
          'This device could not save its settings: ${e.message}. The bind '
          'address is unchanged.',
        ),
      );
      return;
    }
    state.recordBindAddress(address.address);
    state.recordOutcome(SettingsSaved(_saved(address)));
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
