import 'package:dsync/dsync_core/identity/paired_device_store.dart';

import '../../app_bootstrap.dart';
import '../../app_controller.dart';
import '../../device_identity_row.dart';
import 'devices_view_state.dart';

/// Input methods of the Devices page: the paired device list, the home page
/// (SPEC §4.4, §13).
///
/// Takes the [AppController] it borrows the application from as a
/// constructor argument, per the controller role in `app_scope.dart`. The
/// device rows themselves are `AppState`'s and the page reads them from
/// there; this controller only turns the outcomes of what the page asks for
/// — refresh, revoke — into the rendered values on [state].
///
/// Navigation is not an input here. Tapping a row opens Run setup and the
/// empty state points at Pair, but both destinations are other features and
/// neither is routed yet, so the page takes them as callbacks carrying a
/// device id (`DevicesPage.onOpenRunSetup`) — cross-feature handoff carries
/// an id, not data — and the entrypoint wires them to routes.
class DevicesController {
  DevicesController(this.app);

  final AppController app;

  /// The view state this controller renders into; owned here, disposed here.
  final DevicesViewState state = DevicesViewState();

  /// SPEC §4.4's warning for this device's own certificate with the remedy
  /// appended, or `null` while there is nothing to warn about — either
  /// because expiry is outside the window or because bootstrap has not
  /// produced an identity to check.
  ///
  /// `core` renders the fact (`certificate for this host expires in N
  /// days`) and the remedy is appended here rather than in the widget or in
  /// `AppBootstrapReady`: what to do about it is a decision about this head
  /// — it is the This device page's Renew action, on this head, since the
  /// head owns the identity store it would re-issue from — and `AppState`
  /// carries facts, not advice. A getter over `AppState.bootstrap` rather
  /// than a field on [state] so the line is never a second copy of the gate.
  String? get ownCertificateWarning => switch (app.state.bootstrap) {
    AppBootstrapReady(
      identity: DeviceIdentityRow(:final certificateWarning?),
    ) =>
      '$certificateWarning. Renew it under This device.',
    AppBootstrapReady() ||
    AppBootstrapLoading() ||
    AppBootstrapFailed() => null,
  };

  /// Re-reads the store into `AppState.devices`, for a pull-to-refresh or
  /// to pick up a change made behind this process's back. A store that has
  /// gone corrupt since bootstrap lands on [DevicesViewState.error] rather
  /// than escaping: the list keeps its last good rows, and the message —
  /// `core`'s own, naming the file — is what the user needs to act on.
  Future<void> refresh() async {
    try {
      await app.refreshDevices();
    } on PairedDeviceStoreCorruptException catch (e) {
      state.recordError(e.toString());
      return;
    }
    state.clearError();
  }

  /// Revokes [deviceId] locally (SPEC §4.4) and re-renders the list. The
  /// confirmation happens before this is called; by here the user has been
  /// told the revocation is one-sided. An id that matches nothing is a
  /// stale row, shown as a message while the refresh removes the row; a
  /// store that has gone corrupt is shown as [refresh] shows it.
  Future<void> revoke(String deviceId) async {
    final String? failure;
    try {
      failure = await app.revoke(deviceId);
    } on PairedDeviceStoreCorruptException catch (e) {
      state.recordError(e.toString());
      return;
    }
    if (failure == null) {
      state.clearError();
    } else {
      state.recordError(failure);
    }
  }

  void dispose() => state.dispose();
}
