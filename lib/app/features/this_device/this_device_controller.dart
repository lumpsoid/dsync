import '../../app_bootstrap.dart';
import '../../app_controller.dart';
import '../../device_identity_row.dart';
import 'this_device_view_state.dart';

/// Input methods of the This device page: this installation's own identity
/// (SPEC §4.4, §13) — what it is called, what id peers pin it by, and the
/// two things that can be done to it.
///
/// Takes the [AppController] it borrows the application from as a
/// constructor argument, per the controller role in `app_scope.dart`. The
/// identity itself is `AppState`'s — it is the gate's own value — and the
/// page reads it from there through [identity]; this controller only turns
/// the outcomes of what the page asks for into the rendered values on
/// [state].
///
/// **Renaming is a renewal.** SPEC §4.4 calls the name cosmetic, and it is
/// — a peer pins the public key, not the subject — but the certificate is
/// the only place this host records what it calls itself, so changing it
/// re-issues the certificate under the same key. Both actions here are
/// therefore the same write with the same consequence, which is why they
/// share one [IdentityOutcome] and why [_reissued] says the same thing
/// about both: the id does not move, so no pairing is lost, and the bytes
/// do, so a peer cannot be connected to until it has met them.
class ThisDeviceController {
  ThisDeviceController(this.app);

  final AppController app;

  /// The view state this controller renders into; owned here, disposed here.
  final ThisDeviceViewState state = ThisDeviceViewState();

  /// This device as the gate rendered it, or `null` before bootstrap has
  /// produced one. A getter over `AppState.bootstrap` rather than a field
  /// on [state], so the page can never show an identity the gate has since
  /// replaced.
  DeviceIdentityRow? get identity => switch (app.state.bootstrap) {
    AppBootstrapReady(:final identity) => identity,
    AppBootstrapLoading() || AppBootstrapFailed() => null,
  };

  /// Resolves the state directory into [ThisDeviceViewState.stateDirPath] —
  /// what the page asks for on mounting. A path lookup, not a filesystem
  /// read: the core resolved it at `init`, and nothing here checks
  /// whether the directory exists, because the identity the page is showing
  /// was loaded out of it.
  Future<void> loadStateDirPath() async {
    state.recordStateDirPath((await app.dirs).stateDir);
  }

  /// Re-issues this device's certificate under its existing key, keeping
  /// its name (SPEC §4.4, the write `dsync pair renew` makes). The
  /// confirmation happens before this is called; by here the user has been
  /// told what it costs.
  Future<void> renew() => _reissue(commonName: null);

  /// Re-issues this device's certificate under [name] — renaming it. An
  /// empty or blank name is refused here rather than at the certificate:
  /// the page has a field the user can fix, and a certificate is a poor
  /// place to discover a blank one.
  Future<void> rename(String name) {
    final trimmed = name.trim();
    if (trimmed.isEmpty) {
      state.recordOutcome(const IdentityFailed(_nameRequired));
      return Future.value();
    }
    return _reissue(commonName: trimmed);
  }

  /// The write both actions make, and the one place either can fail.
  Future<void> _reissue({required String? commonName}) async {
    state.recordOutcome(const IdentityWorking());
    final failure = await app.renewIdentity(commonName: commonName);
    state.recordOutcome(
      failure == null
          ? IdentitySucceeded(_reissued(renamedTo: commonName))
          : IdentityFailed(failure),
    );
  }

  void dispose() => state.dispose();
}

/// What a successful re-issue means, in the user's words: the reassurance
/// first (nothing was lost), then the cost (SPEC §4.4 — a peer anchors on
/// the bytes it holds, and it only learns new ones by connecting here).
String _reissued({required String? renamedTo}) {
  final what = renamedTo == null
      ? 'Certificate renewed.'
      : 'Renamed to "$renamedTo" and certificate re-issued.';
  return '$what This device keeps its id, so no pairing is lost. Paired '
      'devices pick the new certificate up the next time they connect to '
      'this device; until each has, runs started from here to that device '
      'are refused.';
}

const _nameRequired = 'Give this device a name.';
