import '../../app_bootstrap.dart';
import '../../app_controller.dart';
import '../../core_link/models/core_failure.dart';
import '../../device_identity_row.dart';
import 'devices_view_state.dart';

/// Input methods of the Devices page: the paired device list, the home page
/// (SPEC §4.4, §13).
///
/// Takes the [AppController] it borrows the application from as a
/// constructor argument, per the controller role in `app_scope.dart`. The
/// device rows themselves are `AppState`'s and the page reads them from
/// there; this controller turns the outcome of the one thing the page asks
/// for — a refresh — into the rendered values on [state], and renders the
/// lines that are a join over more of `AppState` than one row holds
/// ([ownCertificateWarning], [savedRunLines]) as getters over it, so they
/// are never a second copy of what they are derived from.
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

  /// How many saved runs name each paired device, as the line the list row
  /// shows, keyed by device id. A device no saved run names is absent from
  /// the map rather than present with a zero: nothing is owed to a device
  /// that has never been run with — the row's own "Set up run" action is
  /// already the whole of what there is to say about it.
  ///
  /// **This join lives here and not on `PairedDeviceRow.render` because it
  /// spans both of `AppState`'s lists.** `AppController.refreshProfiles`
  /// already renders a `ProfileRow` *from* the paired-device store, so a
  /// device row that rendered itself from the profile list would make the
  /// two refreshes depend on each other in both directions and the order
  /// they ran in would start to matter. A controller sits above both lists
  /// and holds neither, so the join is a read of two things the head
  /// already has, re-derived on every build from whatever is current.
  ///
  /// A `Map` rather than a per-row call so the page pays one pass over the
  /// profiles for the whole list, and so the page still only looks a
  /// rendered line up rather than counting anything itself.
  Map<String, String> get savedRunLines {
    final counts = <String, int>{};
    for (final profile in app.state.profiles) {
      counts.update(profile.peerDeviceId, (n) => n + 1, ifAbsent: () => 1);
    }
    return {
      for (final MapEntry(key: deviceId, value: count) in counts.entries)
        deviceId: count == 1 ? '1 saved run' : '$count saved runs',
    };
  }

  /// Re-reads the store into `AppState.devices`, for a pull-to-refresh or
  /// to pick up a change made behind this process's back. A store that has
  /// gone corrupt since bootstrap lands on [DevicesViewState.error] rather
  /// than escaping: the list keeps its last good rows, and the message —
  /// `core`'s own, naming the file — is what the user needs to act on.
  Future<void> refresh() async {
    try {
      await app.refreshDevices();
    } on CoreFailure catch (e) {
      state.recordError(e.message);
      return;
    }
    state.clearError();
  }

  void dispose() => state.dispose();
}
