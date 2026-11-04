import 'package:flutter/foundation.dart';

import 'app_bootstrap.dart';
import 'core_link/models/device_identity_info.dart';
import 'device_identity_row.dart';
import 'paired_device_row.dart';
import 'profile_row.dart';
import 'theme_preference.dart';
import 'unsaved_run_row.dart';

/// The one application state of the Flutter head (SPEC §13, §16): whether
/// the head has bootstrapped enough to show a page at all — and, once it
/// has, what this device is — and who it is paired with.
///
/// A `ChangeNotifier` of already-rendered values, exactly as every feature's
/// view state is (see the view-state role in `app_scope.dart`), and for the
/// same reason: nothing here is a core type, so no page can branch on
/// domain data. Own-certificate expiry arrives as the warning line to
/// show, a peer as a [PairedDeviceRow] of strings and counts, the gate as a
/// sealed [AppBootstrap] a widget switches over.
///
/// The paired devices live here, not on the Devices page's view state,
/// because two features write them: Devices revokes, Pair adds, and a
/// successful pair must appear in the list without a reload. One list with
/// one writer — `AppController` — is how that stays true. The saved
/// profiles are here for the same reason: Run setup saves them, the
/// profiles home deletes them, and the home list (now under a pushed page)
/// must show both without a reload.
///
/// The theme lives here because the app's root draws in it and the Settings
/// page changes it: one value the whole app rebuilds from, so a choice
/// applies the moment it is saved.
///
/// The mutators are the controller's, not a widget's: they are the only
/// way in, they are named for the transition they record, and there is no
/// property setter on any field. A page reads; only `AppController`
/// writes.
class AppState extends ChangeNotifier {
  AppBootstrap _bootstrap = const AppBootstrapLoading();
  List<PairedDeviceRow> _devices = const [];
  List<ProfileRow> _profiles = const [];
  List<UnsavedRunRow> _unsavedRuns = const [];
  ThemePreference _theme = ThemePreference.system;

  /// The gate: loading until `AppController.bootstrap()` has run, then
  /// ready — carrying this device's id and its expiry warning — or failed
  /// with the message to show.
  AppBootstrap get bootstrap => _bootstrap;

  /// The paired devices as rows, in the store's order. Empty both before
  /// bootstrap and on a host that has paired with nobody; the gate, not
  /// this list, says which.
  List<PairedDeviceRow> get devices => _devices;

  /// The saved profiles as rows, in the store's order. Empty before the
  /// profiles home's first read of the store; the home page's error line,
  /// not this list's emptiness, says when the store could not be read.
  List<ProfileRow> get profiles => _profiles;

  /// The runs no saved profile claims that did not finish, listed with the
  /// profiles and read the same way.
  List<UnsavedRunRow> get unsavedRuns => _unsavedRuns;

  /// Which brightness the app draws in: the device's own until the stored
  /// choice has been read, and whenever it cannot be.
  ThemePreference get theme => _theme;

  /// Records a bootstrap transition. `AppController` only.
  void recordBootstrap(AppBootstrap bootstrap) {
    _bootstrap = bootstrap;
    notifyListeners();
  }

  /// Records [identity] as this head's own, and the gate as ready — the
  /// one place the core's identity becomes an [AppBootstrapReady].
  /// `AppController` only.
  ///
  /// Both the first bootstrap and every later re-issue (a renew, a rename)
  /// come through here, so the gate's identity is always the rendering of
  /// the certificate that is on disk *now*, and there is no second copy to
  /// keep in step with it.
  void recordReadyIdentity(DeviceIdentityInfo identity) {
    recordBootstrap(AppBootstrapReady(DeviceIdentityRow.render(identity)));
  }

  /// Replaces the device list with a freshly rendered one. `AppController`
  /// only.
  void recordDevices(List<PairedDeviceRow> devices) {
    _devices = List.unmodifiable(devices);
    notifyListeners();
  }

  /// Replaces the profile list, and the unsaved runs listed with it, with
  /// freshly rendered ones. `AppController` only.
  void recordProfiles(
    List<ProfileRow> profiles, {
    List<UnsavedRunRow> unsavedRuns = const [],
  }) {
    _profiles = List.unmodifiable(profiles);
    _unsavedRuns = List.unmodifiable(unsavedRuns);
    notifyListeners();
  }

  /// Records [theme] as the one the app draws in. `AppController` only.
  void recordTheme(ThemePreference theme) {
    _theme = theme;
    notifyListeners();
  }
}
