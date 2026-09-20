import 'dart:io';

import 'package:dsync/dsync_core/identity/self_signed_certificate.dart';
import 'package:dsync/dsync_core/temp_file.dart';
import 'package:dsync/dsync_core/models/device_identity.dart';
import 'package:dsync/dsync_core/state_dir.dart';

/// Loads or creates this installation's device identity (SPEC §4.4),
/// persisted in the state directory (SPEC §8.3) beside the archives and
/// their locks.
///
/// A concrete class over a real directory path, not an interface —
/// `JsonlArchiveStore` and `ReplicaLock` are the house pattern for a
/// state-dir resident, and SPEC §14 tests core logic against real temporary
/// directories, so there is no test here that would force an abstraction.
///
/// [loadOrCreate] is the whole surface: generate-once, reuse-after. The
/// first call against a state directory with no identity in it generates a
/// fresh one and writes it; every later call reads the same two files back
/// unchanged. There is no update path — nothing here ever rotates or
/// replaces an identity that already exists.
///
/// **Private key permissions.** The certificate file is written with
/// whatever mode a freshly created file gets — it is not a secret; a peer's
/// pin is on its bytes, not on keeping them confidential (SPEC §4.4). The
/// private key is the one file here that matters, and what happens to it is
/// the same honesty `AgentListener.bindUnix` gives the unix socket, for the
/// same underlying reason: `dart:io` has no `chmod`. `LocalAgent._applyMode`
/// already shells out to the `chmod` binary for exactly that reason, and
/// [_writePrivateKey] does the same, best-effort, immediately after writing
/// the key: `chmod 600`, restricting it to owner read/write. What that does
/// and does not guarantee:
/// - It is not atomic with the write. Between the key hitting disk and the
///   `chmod` completing, the file exists at whatever mode the OS and umask
///   give a freshly created file — typically group- and world-readable. A
///   process racing this one on the same host, in that window, is not
///   stopped.
/// - It depends on a `chmod` binary being on `PATH`. Where there is none —
///   Windows is the case this project already knows about (SPEC §3) — the
///   call fails and is swallowed here exactly as `_applyMode` swallows it
///   there, and the key is left at the filesystem's default mode with
///   nothing further attempted.
/// - It says nothing about the directories above it. As `bindUnix`'s own
///   doc comment already states for the socket case, what actually gates
///   access is whether another user can traverse every directory from the
///   filesystem root down to this file, which is a property of the state
///   directory and its ancestors, not of this one file — and not something
///   this class creates with any particular mode or checks.
///
/// This is a real reduction of exposure on the common case — a POSIX host
/// with `chmod` on `PATH` and no adversary already running as another user
/// on the same machine at the exact moment of generation — and not a
/// guarantee beyond it.
class DeviceIdentityStore {
  final Directory _stateDir;

  DeviceIdentityStore(this._stateDir);

  /// Resolves the standard identity location under the state directory
  /// (SPEC §8.3, §4.4). See [resolveStateDir]. [platform] is required, not
  /// defaulted: every caller states which of SPEC §8.3's rules it means
  /// rather than silently getting Linux's — see
  /// `lib/cli/host_platform.dart` for where the CLI head's real answer
  /// comes from.
  factory DeviceIdentityStore.forStateDir({
    Map<String, String> environment = const {},
    required StateDirPlatform platform,
  }) => DeviceIdentityStore(Directory(resolveStateDir(environment, platform)));

  File get _certificateFile => File('${_stateDir.path}/identity.crt');
  File get _privateKeyFile => File('${_stateDir.path}/identity.key');

  /// Whether an identity has been generated here — both files present.
  Future<bool> exists() async =>
      await _certificateFile.exists() && await _privateKeyFile.exists();

  /// Loads the persisted identity, generating and writing one first if the
  /// state directory holds none yet. [commonName] is used only for that
  /// first generation (see [generateDeviceIdentity]) — an identity that
  /// already exists is read back exactly as stored, never regenerated.
  Future<DeviceIdentity> loadOrCreate({required String commonName}) async {
    final hasCertificate = await _certificateFile.exists();
    final hasPrivateKey = await _privateKeyFile.exists();

    if (hasCertificate && hasPrivateKey) {
      return DeviceIdentity(
        certificatePem: await _certificateFile.readAsString(),
        privateKeyPem: await _privateKeyFile.readAsString(),
      );
    }
    if (hasCertificate || hasPrivateKey) {
      // Generation writes the certificate, then the key (below); a crash
      // between the two leaves exactly one of them behind. Regenerating here
      // would silently mint a *different* identity than whichever half
      // survived — changing this installation's device id out from under
      // any pairing already recorded against it, which is worse than
      // refusing to proceed.
      throw DeviceIdentityIncompleteException(_stateDir.path);
    }

    final identity = generateDeviceIdentity(commonName: commonName);
    await _stateDir.create(recursive: true);
    await _certificateFile.writeAsString(identity.certificatePem, flush: true);
    await _writePrivateKey(identity.privateKeyPem);
    return identity;
  }

  /// Re-issues the persisted certificate under the persisted private key
  /// (`dsync pair renew`, SPEC §4.4) and returns the renewed identity. The
  /// key file is untouched — that is the whole point, the device id stays
  /// — and the certificate is written to a scratch path and renamed over
  /// the old one, so a crash mid-write leaves the old certificate, never a
  /// truncated one. Throws [DeviceIdentityIncompleteException] via
  /// [loadOrCreate] when there is nothing to renew; [now] is injectable for
  /// the same reason [renewDeviceIdentity]'s is.
  ///
  /// [commonName] re-issues under a different name instead of the persisted
  /// one — renaming this device. It is the same write, at the same cost, for
  /// the reason [renewDeviceIdentity] gives: the name lives in the
  /// certificate, so changing it means new bytes, and new bytes mean every
  /// peer has to meet them before this host can connect to it again.
  Future<DeviceIdentity> renew({DateTime? now, String? commonName}) async {
    final existing = await loadOrCreate(commonName: 'unused');
    final renewed = renewDeviceIdentity(
      existing,
      now: now,
      commonName: commonName,
    );
    final scratch = File(tempPathFor(_certificateFile.path, 0));
    await scratch.writeAsString(renewed.certificatePem, flush: true);
    await scratch.rename(_certificateFile.path);
    return renewed;
  }

  /// Writes the private key, then best-effort restricts it to owner
  /// read/write. See the class doc comment for exactly what that does and
  /// does not guarantee.
  Future<void> _writePrivateKey(String pem) async {
    await _privateKeyFile.writeAsString(pem, flush: true);
    try {
      await Process.run('chmod', ['600', _privateKeyFile.path]);
    } on ProcessException {
      // No chmod on this host — the key is left at whatever mode the
      // filesystem gave it. See the class doc comment.
    }
  }
}

/// Thrown by [DeviceIdentityStore.loadOrCreate] when the state directory
/// holds exactly one of the certificate and private key files rather than
/// both or neither — the signature of a crash partway through the first
/// generation.
class DeviceIdentityIncompleteException implements Exception {
  final String stateDirPath;

  const DeviceIdentityIncompleteException(this.stateDirPath);

  @override
  String toString() =>
      'Device identity in $stateDirPath is incomplete: found only one of '
      'the certificate and private key files. Remove both and re-run to '
      'generate a fresh identity.';
}
