import 'dart:io';

import 'package:dsync/dsync_core/identity/certificate_expiry.dart';
import 'package:dsync/dsync_core/identity/device_identity_store.dart';
import 'package:dsync/dsync_core/identity/paired_device_store.dart';
import 'package:dsync/dsync_core/models/device_identity.dart';

import 'app_bootstrap.dart';
import 'app_paths.dart';
import 'app_state.dart';
import 'paired_device_row.dart';

/// The head's bootstrap orchestrator: owns [AppState], the paths, and the
/// identity every feature controller borrows rather than opens for itself
/// (SPEC §5, §13). The only writer of [state].
///
/// A controller in this head takes what it needs as constructor arguments so
/// a test can hand it fakes and a scope can build it with real ones — see
/// the conventions in `app_scope.dart`. What this one takes is
/// [resolvePaths], a function rather than an [AppPaths], because the real
/// lookup (`AppPaths.forThisDevice`) is asynchronous and a scope's factory
/// is not: the scope can construct the controller synchronously and the
/// paths are resolved once, on first use, by whichever bootstrap step needs
/// them first. A test passes `() async => AppPaths(tempDir.path,
/// documentsDir: ...)`.
///
/// [now] is the clock the SPEC §4.4 expiry rule reads — the same callback
/// shape `pair list` takes — so a test can present a nearly-expired
/// certificate by moving the clock rather than the certificate. The scope
/// passes `DateTime.now` explicitly; there is no default, so a wrong clock
/// cannot arrive by omission.
///
/// Loading and deciding are kept apart, per CLAUDE.md: [bootstrap] and
/// [refreshDevices] fetch, then hand each `PairedDevice` to
/// [PairedDeviceRow.render] and each certificate to
/// `certificateExpiryWithin` for the verdict. Nothing here interprets a
/// certificate itself.
///
/// The entrypoint that calls [bootstrap] and gates routing on
/// [AppState.bootstrap] is the last phase's; until then `_DeferredHead`
/// renders and this is the seam it will replace.
class AppController {
  AppController(this._resolvePaths, {required this.now});

  final Future<AppPaths> Function() _resolvePaths;
  final DateTime Function() now;
  Future<AppPaths>? _paths;

  /// The application state this controller renders into. Owned here, not by
  /// the scope, so the controller can dispose it along with itself.
  final AppState state = AppState();

  /// The head's directories, resolved once and shared — a feature that needs
  /// the state dir reads it from here rather than asking the platform again.
  Future<AppPaths> get paths => _paths ??= _resolvePaths();

  /// The paired-device store over the resolved state dir (SPEC §4.4, §8.3).
  /// Built from [paths] rather than `PairedDeviceStore.forStateDir` because
  /// the state dir is already resolved once, in [AppPaths]; resolving it a
  /// second time through `core` would be a second place for it to differ.
  /// Shared with the Pair feature, which adds through it and then asks
  /// [refreshDevices] to show the result.
  Future<PairedDeviceStore> get pairedDevices async =>
      PairedDeviceStore(File('${(await paths).stateDir}/paired-devices.json'));

  /// Runs the sequence a page depends on — identity first, then the
  /// paired-device store — and moves [AppState.bootstrap] from loading to
  /// ready or failed. Idempotent in effect: a second call re-reads the same
  /// files and lands on the same case.
  ///
  /// The two failures it renders are `core`'s deliberate refusals, kept as
  /// refusals rather than recovered from: a `DeviceIdentityIncompleteException`
  /// (regenerating would change this device's id under every recorded
  /// pairing) and a `PairedDeviceStoreCorruptException` (an empty set means
  /// "trust nobody", so damaged bytes must not read as that). Each
  /// exception's own message is what is shown — it names the path and what
  /// the user can do. Anything else is a defect and propagates as one.
  Future<void> bootstrap() async {
    state.recordBootstrap(const AppBootstrapLoading());
    final DeviceIdentity identity;
    try {
      identity = await loadOrCreateIdentity();
      await refreshDevices();
    } on DeviceIdentityIncompleteException catch (e) {
      state.recordBootstrap(AppBootstrapFailed(e.toString()));
      return;
    } on PairedDeviceStoreCorruptException catch (e) {
      state.recordBootstrap(AppBootstrapFailed(e.toString()));
      return;
    }
    state.recordBootstrap(
      AppBootstrapReady(
        deviceId: identity.deviceId,
        certificateWarning: certificateExpiryWithin(
          identity.certificateDer,
          owner: CertificateExpiry.thisHost,
          now: now(),
        )?.message,
      ),
    );
  }

  /// Re-reads the store and re-renders [AppState.devices] — the call the
  /// Pair feature makes after a successful pair so the new device appears
  /// without a reload, and the one that picks up a change made to the
  /// store behind this process's back.
  ///
  /// Throws `PairedDeviceStoreCorruptException` as the store does: a store
  /// that was readable at bootstrap and is not now is the same refusal
  /// [bootstrap] renders, and the caller decides how to surface it —
  /// [bootstrap] as the failed gate, a feature as its own error.
  Future<void> refreshDevices() async {
    final at = now();
    final devices = await (await pairedDevices).load();
    state.recordDevices([
      for (final device in devices) PairedDeviceRow.render(device, now: at),
    ]);
  }

  /// Revokes the device with [deviceId] (SPEC §4.4) and re-renders the
  /// list. Returns `null` on success, or the message to show when nothing
  /// matched — a `PairedDeviceNotFoundException` rendered rather than
  /// thrown, because a stale row tapped after the device was revoked
  /// elsewhere is a thing to tell the user, not a crash. The list is
  /// refreshed on that path too, so the stale row goes away with the
  /// message.
  Future<String?> revoke(String deviceId) async {
    String? failure;
    try {
      await (await pairedDevices).revoke(deviceId);
    } on PairedDeviceNotFoundException catch (e) {
      failure = e.toString();
    }
    await refreshDevices();
    return failure;
  }

  /// Loads this installation's identity, generating one on first launch
  /// (SPEC §4.4). Generate-once, reuse-after: a second call reads the same
  /// two files back rather than minting a new device id, which would
  /// invalidate every pairing recorded against this device.
  ///
  /// The common name is fixed rather than derived from the host because it
  /// authenticates nothing: the device id is the SHA-256 of the
  /// certificate's SubjectPublicKeyInfo, and a peer pins that public key,
  /// not the subject — SPEC §4.4 calls the name cosmetic outright. The CLI
  /// uses the hostname there because it has one to hand; a mobile head has
  /// nothing as meaningful, and a constant is honest about that.
  ///
  /// Throws `DeviceIdentityIncompleteException` when exactly one of the two
  /// identity files survived an earlier crash — deliberately not papered
  /// over here, for the reason the store gives: regenerating would change
  /// this installation's device id under every recorded pairing.
  /// [bootstrap] is where that becomes a rendered failure.
  Future<DeviceIdentity> loadOrCreateIdentity() async {
    final stateDir = Directory((await paths).stateDir);
    return DeviceIdentityStore(stateDir).loadOrCreate(commonName: 'dsync-app');
  }

  void dispose() => state.dispose();
}
