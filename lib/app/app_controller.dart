import 'dart:io';

import 'app_bootstrap.dart';
import 'app_settings_store.dart';
import 'app_state.dart';
import 'core_link/core_link.dart';
import 'core_link/models/core_dirs.dart';
import 'core_link/models/core_failure.dart';
import 'core_link/models/entry_draft.dart';
import 'core_link/models/paired_device_info.dart';
import 'core_link/models/profile_draft.dart';
import 'core_link/models/profile_entry.dart';
import 'paired_device_row.dart';
import 'profile_row.dart';

/// The head's bootstrap orchestrator: owns [AppState] and the one
/// [CoreLink] every feature controller borrows (SPEC §5, §13). The only
/// writer of [state].
///
/// A controller in this head takes what it needs as constructor arguments
/// so a test can hand it fakes and a scope can build it with real ones —
/// see the conventions in `app_scope.dart`. What this one takes is [core]
/// and [supportDir], a function rather than a path, because the real
/// lookup is asynchronous (`path_provider`) and a scope's factory is not:
/// the core is initialised once, on first use, by whichever step needs it
/// first ([dirs]). A test passes a `CoreLink` over a fake hub channel and
/// `() async => null`.
///
/// [now] is the clock the head's own relative dates read ("2 hours ago"),
/// passed explicitly by the scope so a wrong clock cannot arrive by
/// omission. The SPEC §4.4 expiry rule is the core's: it arrives as the
/// warning line on each row.
///
/// Every refusal the core makes is a `CoreFailure` carrying the core's own
/// words. The writes below render it as the message to show (`String?`,
/// `null` on success) because each is a thing to tell the user, not a
/// crash; the reads ([refreshDevices], [refreshProfiles]) throw it for
/// the caller to surface where it belongs.
class AppController {
  AppController(this.core, {required this.supportDir, required this.now});

  /// What an identity created on this device is called. It authenticates
  /// nothing — the device id is the hash of the public key and a peer pins
  /// that, SPEC §4.4 calls the name cosmetic — and a mobile head has no
  /// hostname as meaningful as the CLI's, so a constant is honest.
  static const deviceName = 'dsync-app';

  final CoreLink core;

  /// The directory the core keeps its state under, where the head must
  /// supply one (Android, iOS); `null` on the desktop.
  final Future<String?> Function() supportDir;
  final DateTime Function() now;
  Future<CoreDirs>? _dirs;

  /// The application state this controller renders into. Owned here, not by
  /// the scope, so the controller can dispose it along with itself.
  final AppState state = AppState();

  /// Where the core keeps its state, from its answer to `init` — sent once,
  /// on first use. A failed `init` is forgotten so the next read (a retried
  /// bootstrap) sends it again.
  Future<CoreDirs> get dirs => _dirs ??= _init();

  Future<CoreDirs> _init() async {
    try {
      return await core.init(
        supportDir: await supportDir(),
        deviceName: deviceName,
      );
    } on Object {
      _dirs = null;
      rethrow;
    }
  }

  /// The head's own preferences, in the core's state directory beside the
  /// paired-device store: the directory is the core's answer to `init`, so
  /// the head never writes where an older build kept its state (plan D0).
  ///
  /// Deliberately not read during [bootstrap]: a damaged settings file
  /// loses convenience, not trust (see `AppSettingsStore`), so it surfaces
  /// on the Settings page rather than keeping the app off its home list.
  Future<AppSettingsStore> get settings async =>
      AppSettingsStore(File('${(await dirs).stateDir}/settings.json'));

  /// Initialises the core, then loads this device's identity (created on
  /// first launch) and the paired devices, and moves [AppState.bootstrap]
  /// from loading to ready or failed. Idempotent in effect.
  ///
  /// A refusal is rendered as the failed gate with the core's message —
  /// a half-written identity (regenerating it would change this device's
  /// id under every recorded pairing) or a damaged device store (an empty
  /// set means "trust nobody", so damaged bytes must not read as that)
  /// are both the core's to refuse, and its words name the file.
  Future<void> bootstrap() async {
    state.recordBootstrap(const AppBootstrapLoading());
    try {
      await dirs;
      final identity = await core.showIdentity();
      await refreshDevices();
      state.recordReadyIdentity(identity);
    } on CoreFailure catch (e) {
      state.recordBootstrap(AppBootstrapFailed(e.message));
    }
  }

  /// Re-issues this device's certificate under its existing key (SPEC §4.4,
  /// `dsync pair renew`), optionally under a new [commonName], and records
  /// the re-rendered identity. The device id does not move; the bytes do,
  /// and until each peer has met them by connecting here, runs started from
  /// here to it are refused — the caller has already put that in front of
  /// the user. Returns `null` on success, or the message to show.
  Future<String?> renewIdentity({String? commonName}) async {
    try {
      state.recordReadyIdentity(
        await core.renewIdentity(commonName: commonName),
      );
    } on CoreFailure catch (e) {
      return e.message;
    }
    return null;
  }

  /// Renames the device with [deviceId] to [name] (SPEC §4.4: this host's
  /// own label for the peer). A profile row prints its device's name, so
  /// the profiles are re-read after it.
  Future<String?> renameDevice(String deviceId, String name) =>
      _deviceWriteShownOnProfiles(() => core.renameDevice(deviceId, name));

  /// Authorizes the device to reach [rootPath] on this host (SPEC §4.4,
  /// `dsync pair grant`); the core expands `~` before it stores it.
  Future<String?> grantRoot(String deviceId, String rootPath) =>
      _deviceWrite(() => core.grantRoot(deviceId, rootPath));

  /// Withdraws [rootPath], exactly as the grant list holds it.
  Future<String?> revokeRoot(String deviceId, String rootPath) =>
      _deviceWrite(() => core.withdrawGrant(deviceId, rootPath));

  /// Records [address] (`host` or `host:port`) as where to dial the device
  /// next — the field a connection records, so a typed correction and an
  /// address proved by a run land in the same place.
  Future<String?> updateDeviceAddress(String deviceId, String address) =>
      _deviceWrite(() => core.setDeviceAddress(deviceId, address));

  /// Records that the user compared the ids and found them equal.
  Future<String?> markDeviceVerified(String deviceId) =>
      _deviceWrite(() => core.verifyDevice(deviceId));

  /// Takes that confirmation back.
  Future<String?> clearDeviceVerification(String deviceId) =>
      _deviceWrite(() => core.clearVerification(deviceId));

  /// Revokes the device (SPEC §4.4): local only, nothing is sent to it. A
  /// profile naming it now renders broken, so the profiles are re-read
  /// after it.
  Future<String?> revoke(String deviceId) =>
      _deviceWriteShownOnProfiles(() => core.revokeDevice(deviceId));

  /// A pairing the core has just recorded: the new device joins the list,
  /// and a profile naming it — one left broken by an earlier revoke — can
  /// be run again. Throws `CoreFailure` when the devices cannot be re-read,
  /// as [refreshDevices] does; the profiles' re-read never throws.
  Future<void> devicePaired() async {
    await refreshDevices();
    await _refreshProfilesAfterWrite();
  }

  /// A run's attempt has stopped being live — finished, stopped, paused or
  /// failed — which is when the core writes or clears the run marker a
  /// profile row warns with (SPEC §7.6). Never throws: the run feature
  /// tells this in passing and has nothing to show a failure on.
  Future<void> runEnded() => _refreshProfilesAfterWrite();

  /// One change to the paired devices, answered with the list as it now
  /// stands. A refusal is the message to show, and the list is re-read on
  /// that path too, so a stale row (a device revoked elsewhere) goes away
  /// with its message; a failure of that re-read propagates.
  Future<String?> _deviceWrite(
    Future<List<PairedDeviceInfo>> Function() write,
  ) async {
    try {
      _recordDevices(await write());
    } on CoreFailure catch (e) {
      await refreshDevices();
      return e.message;
    }
    return null;
  }

  /// A [_deviceWrite] whose change a profile row also shows (its device's
  /// name, or whether it is still paired). The profiles are read after
  /// the write lands, since the core lists them from the device store as
  /// it now stands; the devices' own list is the write's answer, so there
  /// is nothing to order between the two lists. A refusal changed nothing
  /// a profile shows, so only a success re-reads them.
  Future<String?> _deviceWriteShownOnProfiles(
    Future<List<PairedDeviceInfo>> Function() write,
  ) async {
    final failure = await _deviceWrite(write);
    if (failure == null) await _refreshProfilesAfterWrite();
    return failure;
  }

  /// Re-reads the profiles after a write elsewhere changed what their rows
  /// show. The write has already landed, so a store that cannot be read
  /// does not turn it into a failure: the list keeps its last rows, and
  /// the Profiles page's own [refreshProfiles] surfaces the store's message
  /// on its next read.
  Future<void> _refreshProfilesAfterWrite() async {
    try {
      await refreshProfiles();
    } on CoreFailure {
      // Left for the Profiles page's own read to surface; see above.
    }
  }

  /// Re-reads the paired devices into [AppState.devices]. Throws
  /// `CoreFailure` when the store cannot be read, for the caller to
  /// surface — [bootstrap] as the failed gate, a feature as its own error.
  Future<void> refreshDevices() async =>
      _recordDevices(await core.listDevices());

  void _recordDevices(List<PairedDeviceInfo> devices) => state.recordDevices([
    for (final device in devices) PairedDeviceRow.render(device),
  ]);

  /// Re-reads the saved profiles into [AppState.profiles]. Each is listed
  /// with the facts its row renders from — its device's name *now*, the
  /// core's check of its local folder, its run marker — so a broken
  /// profile renders its breakage rather than disappearing. Throws
  /// `CoreFailure` for the caller to surface.
  Future<void> refreshProfiles() async =>
      _recordProfiles(await core.listProfiles());

  /// Only the head's own shape — this device's folder with one on a paired
  /// device — is a row. A profile the CLI wrote with another shape, or one
  /// whose file will not load, is the CLI's to run and edit.
  void _recordProfiles(List<ProfileEntry> entries) => state.recordProfiles([
    for (final entry in entries)
      if (entry case final HeadProfile profile) ProfileRow.render(profile),
  ]);

  /// Saves [draft] as the profile [name] and re-renders the list. When
  /// [replacing] names a profile saved under another name, that one is
  /// renamed first, so editing a loaded profile's name moves it rather
  /// than leaving a copy under the old one. Throws `CoreFailure`.
  Future<void> saveProfile(
    String name,
    ProfileDraft draft, {
    String? replacing,
  }) async {
    if (replacing != null && replacing != name) {
      await core.renameProfile(replacing, name);
    }
    _recordProfiles(await core.saveProfile(name, draft));
  }

  /// Points the profile [name]'s entry at [entryIndex] at [localRootPath],
  /// keeping the rest, and re-renders the list — the remedy the home list
  /// offers on a row broken by a lost folder grant. The caller has already
  /// proved the folder usable. Returns `null` on success, or the message to
  /// show.
  Future<String?> relocateProfile(
    String name, {
    required int entryIndex,
    required String localRootPath,
  }) async {
    try {
      final entries = await core.listProfiles();
      final profile = entries.whereType<HeadProfile>().where(
        (profile) => profile.name == name,
      );
      if (profile.isEmpty) {
        _recordProfiles(entries);
        return 'No saved run is called "$name" any more.';
      }
      final saved = profile.single;
      _recordProfiles(
        await core.saveProfile(
          name,
          ProfileDraft(
            peerDeviceId: saved.peerDeviceId,
            entries: [
              for (final (index, entry) in saved.entries.indexed)
                EntryDraft(
                  kind: entry.kind,
                  localRoot: index == entryIndex
                      ? localRootPath
                      : entry.localRoot,
                  remoteRoot: entry.remoteRoot,
                ),
            ],
            jobs: saved.jobs,
            ignorePatterns: saved.ignorePatterns,
          ),
        ),
      );
    } on CoreFailure catch (e) {
      return e.message;
    }
    return null;
  }

  /// Deletes the profile [name] and re-renders the list. Returns `null` on
  /// success, or the message to show; the list is re-read on that path
  /// too, so a stale row goes away with its message.
  Future<String?> deleteProfile(String name) async {
    try {
      _recordProfiles(await core.deleteProfile(name));
    } on CoreFailure catch (e) {
      await refreshProfiles();
      return e.message;
    }
    return null;
  }

  void dispose() => state.dispose();
}
