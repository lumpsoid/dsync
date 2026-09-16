import 'dart:io';

import 'package:dsync/dsync_core/identity/device_identity_store.dart';
import 'package:dsync/dsync_core/models/device_identity.dart';

import 'app_paths.dart';
import 'app_state.dart';

/// The head's bootstrap orchestrator: owns [AppState], the paths, and the
/// identity every feature controller borrows rather than opens for itself
/// (SPEC §5, §13).
///
/// A controller in this head takes what it needs as constructor arguments so
/// a test can hand it fakes and a scope can build it with real ones — see
/// the conventions in `app_scope.dart`. What this one takes is
/// [resolvePaths], a function rather than an [AppPaths], because the real
/// lookup (`AppPaths.forThisDevice`) is asynchronous and a scope's factory
/// is not: the scope can construct the controller synchronously and the
/// paths are resolved once, on first use, by whichever bootstrap step needs
/// them first. A test passes `() async => AppPaths(tempDir.path)`.
///
/// The identity bootstrap here has no caller in the head yet: the sequenced
/// `bootstrap()` that runs it and then loads the paired devices is the next
/// phase's, and the app entrypoint that calls *that* is the last one's. This
/// is the seam they build on.
class AppController {
  AppController(this._resolvePaths);

  final Future<AppPaths> Function() _resolvePaths;
  Future<AppPaths>? _paths;

  /// The application state this controller renders into. Owned here, not by
  /// the scope, so the controller can dispose it along with itself.
  final AppState state = AppState();

  /// The head's directories, resolved once and shared — a feature that needs
  /// the state dir reads it from here rather than asking the platform again.
  Future<AppPaths> get paths => _paths ??= _resolvePaths();

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
  Future<DeviceIdentity> loadOrCreateIdentity() async {
    final stateDir = Directory((await paths).stateDir);
    return DeviceIdentityStore(stateDir).loadOrCreate(commonName: 'dsync-app');
  }
}
