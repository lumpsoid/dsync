import 'models/archive_info.dart';
import 'models/core_dirs.dart';
import 'models/device_identity_info.dart';
import 'models/filter_preview.dart';
import 'models/filter_row.dart';
import 'models/pair_code_reading.dart';
import 'models/paired_device_info.dart';
import 'models/pairing_window.dart';
import 'models/peer_probe_outcome.dart';
import 'models/profile_draft.dart';
import 'models/profile_entry.dart';
import 'models/run_decision.dart';
import 'models/run_session.dart';
import 'models/run_target.dart';
import 'models/scan_probe_result.dart';
import 'models/serve_addresses.dart';
import 'models/serve_session.dart';

/// The head's one way into the Rust core (plan D10): intent-named calls,
/// each answered by the core, and three kinds of session whose story
/// arrives as a stream.
///
/// An interface because the real implementation cannot run where the
/// head's tests run: `flutter test` cannot load the native library
/// (native/NOTES.md), so controllers are tested against [FakeCoreLink]
/// and the app runs on [RinfCoreLink].
///
/// Every call throws `CoreFailure` with the core's own message when the
/// core refuses or cannot carry it out; anything else thrown is a defect.
abstract interface class CoreLink {
  /// Must come first. [supportDir] is the app's support directory on
  /// Android and iOS; on the desktop it is `null` and the core resolves
  /// its directories as the CLI does. [deviceName] names an identity
  /// created on this device. Answers with where the core keeps its state.
  Future<CoreDirs> init({String? supportDir, required String deviceName});

  /// This device's identity, created on first use.
  Future<DeviceIdentityInfo> showIdentity();

  /// The same key and device id, a fresh certificate.
  Future<DeviceIdentityInfo> renewIdentity({String? commonName});

  /// Opens a pairing window; whoever redeems it is recorded as [name].
  /// [bind] is an address literal; [advertise] overrides the host the
  /// payload names.
  Future<PairingWindow> showPairing({
    required String name,
    required String bind,
    String? advertise,
    required int servicePort,
  });

  /// The operator's answer for the device waiting in pairing window
  /// [session].
  Future<void> confirmPairing(int session, {required bool accept});

  Future<void> cancelPairing(int session);

  /// What a scanned or pasted pairing code says, before redeeming it.
  Future<PairCodeReading> readPairCode(String text);

  /// Redeems [code], recording the other device as [name].
  Future<PairedDeviceInfo> acceptPairing({
    required String code,
    required String name,
  });

  Future<List<PairedDeviceInfo>> listDevices();

  /// Each change answers with the list as it now stands.
  Future<List<PairedDeviceInfo>> renameDevice(String deviceId, String name);

  Future<List<PairedDeviceInfo>> revokeDevice(String deviceId);

  /// [path] is expanded (`~`) before it is stored.
  Future<List<PairedDeviceInfo>> grantRoot(String deviceId, String path);

  /// [root] exactly as the device's grants hold it.
  Future<List<PairedDeviceInfo>> withdrawGrant(String deviceId, String root);

  /// Where to dial the device from now on: [address] as `host` or
  /// `host:port`, the field a connection records.
  Future<List<PairedDeviceInfo>> setDeviceAddress(
    String deviceId,
    String address,
  );

  /// The operator compared the device's id with the one it shows itself,
  /// and they matched.
  Future<List<PairedDeviceInfo>> verifyDevice(String deviceId);

  /// Takes that confirmation back.
  Future<List<PairedDeviceInfo>> clearVerification(String deviceId);

  /// Whether the device answers and admits this host, at [address]
  /// (`host` or `host:port`) or where it was last reached.
  Future<PeerProbeOutcome> probePeer(String deviceId, {String? address});

  Future<List<ProfileEntry>> listProfiles();

  /// Creates or overwrites [name]. Each change answers with the list.
  Future<List<ProfileEntry>> saveProfile(String name, ProfileDraft draft);

  Future<List<ProfileEntry>> renameProfile(String from, String to);

  Future<List<ProfileEntry>> deleteProfile(String name);

  /// Starts a run of [target]. [address] overrides where the peer is
  /// dialled. When [RunPlan.awaitingDecision], the run waits for
  /// [decideRun].
  Future<RunSession> startRun(
    RunTarget target, {
    required bool dryRun,
    String? address,
  });

  Future<void> decideRun(int session, RunDecision decision);

  /// The first stop is graceful; a second drops the run.
  Future<void> stopRun(int session);

  /// Serves paired devices on [bind]:[port] until [stopServe].
  Future<ServeSession> startServe({required String bind, required int port});

  Future<void> stopServe(int session);

  Future<ServeAddresses> serveAddresses();

  Future<List<ArchiveInfo>> listArchives();

  /// Deletes both sides' archives of [profileId]; answers with the rest.
  Future<List<ArchiveInfo>> clearArchive(String profileId);

  /// The whole tree under [root] counted against [ignorePatterns].
  Future<FilterPreview> previewFilters(
    String root,
    List<String> ignorePatterns,
  );

  /// One folder's entries ([folder] `null`: the root).
  Future<List<FilterRow>> listFilterFolder(
    String root,
    String? folder,
    List<String> ignorePatterns,
  );

  /// Throws `CoreFailure` saying why when [pattern] is not a valid ignore
  /// pattern (SPEC §9).
  Future<void> checkIgnorePattern(String pattern);

  /// Why [path] cannot be a replica root, or `null` when it can (SPEC §3).
  Future<String?> checkFolder(String path);

  /// What scanning [root] costs, [passes] times over.
  Future<ScanProbeResult> probeScan(
    String root, {
    List<String> ignorePatterns = const [],
    int passes = 2,
  });
}
