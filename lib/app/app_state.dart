import 'package:flutter/foundation.dart';

import 'app_bootstrap.dart';
import 'paired_device_row.dart';

/// The one application state of the Flutter head (SPEC §13, §16): whether
/// the head has bootstrapped enough to show a page at all — and, once it
/// has, what this device is — and who it is paired with.
///
/// A `ChangeNotifier` of already-rendered values, exactly as every feature's
/// view state is (see the view-state role in `app_scope.dart`), and for the
/// same reason: nothing here is a `dsync_core` type, so no page can branch
/// on domain data. Own-certificate expiry arrives as the warning line to
/// show, a peer as a [PairedDeviceRow] of strings and counts, the gate as a
/// sealed [AppBootstrap] a widget switches over.
///
/// The paired devices live here, not on the Devices page's view state,
/// because two features write them: Devices revokes, Pair adds, and a
/// successful pair must appear in the list without a reload. One list with
/// one writer — `AppController` — is how that stays true.
///
/// The mutators are the controller's, not a widget's: they are the only
/// way in, they are named for the transition they record, and there is no
/// property setter on any field. A page reads; only `AppController`
/// writes.
class AppState extends ChangeNotifier {
  AppBootstrap _bootstrap = const AppBootstrapLoading();
  List<PairedDeviceRow> _devices = const [];

  /// The gate: loading until `AppController.bootstrap()` has run, then
  /// ready — carrying this device's id and its expiry warning — or failed
  /// with the message to show.
  AppBootstrap get bootstrap => _bootstrap;

  /// The paired devices as rows, in the store's order. Empty both before
  /// bootstrap and on a host that has paired with nobody; the gate, not
  /// this list, says which.
  List<PairedDeviceRow> get devices => _devices;

  /// Records a bootstrap transition. `AppController` only.
  void recordBootstrap(AppBootstrap bootstrap) {
    _bootstrap = bootstrap;
    notifyListeners();
  }

  /// Replaces the device list with a freshly rendered one. `AppController`
  /// only.
  void recordDevices(List<PairedDeviceRow> devices) {
    _devices = List.unmodifiable(devices);
    notifyListeners();
  }
}
