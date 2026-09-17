import 'dart:io';

import 'package:dsync/dsync_core/models/location.dart';
import 'package:dsync/dsync_core/models/paired_device.dart';
import 'package:dsync/dsync_core/scan/scanner.dart';
import 'package:path/path.dart' as p;

import '../../app_controller.dart';
import '../../folder_access.dart';
import '../../run_request.dart';
import '../../sync_profile.dart';
import '../run/replica_connector.dart';
import 'folder_picker.dart';
import 'run_setup_view_state.dart';

/// Input methods of the Run setup page: building the two locations a run
/// needs, blank or from a saved profile (SPEC §2, §4.4, §11.2, §12).
///
/// Takes the [AppController] it borrows the application from as a
/// constructor argument, per the controller role in `app_scope.dart`. It
/// opens no socket: [start] validates and builds a [RunRequest] — the only
/// place one is constructed — and the Run feature is what connects.
///
/// **The local side is any folder this head can prove it can read and
/// write.** Two ways in: a directory under `AppPaths.documentsDir`, created
/// on demand ([createLocalFolder]) and listed for selection ([load]), which
/// needs no grant on either platform; or one the user chooses through the
/// platform's own folder chooser ([pickLocalFolder]), which is how a replica
/// lands somewhere a file manager can also see — on Android the documents
/// directory is app-private, so it alone would confine every sync to files
/// the user cannot otherwise reach.
///
/// A picked folder is *probed*, not trusted: [pickLocalFolder] lists it and
/// writes and deletes one entry in it before offering it as a choice. The
/// probe is plain `dart:io`, which is exactly what `Scanner` and
/// `LocalAgent` scan and write a replica with, so a folder that passes it is
/// scannable by construction and a folder that fails it is refused here —
/// with a line the page raises as a snackbar — rather than mid-run. That is
/// also why the head asks the filesystem rather than a permission API: on
/// Android the chooser's own grant covers the `content://` tree URI it
/// returns and *not* the path that URI converts to, which is openable only
/// under All-files access (`MANAGE_EXTERNAL_STORAGE`, declared in
/// `android/app/src/main/AndroidManifest.xml`), so a failed probe is met by
/// asking for that grant once (`FolderPicker.requestAccess`) and probing
/// again. Paths that convert to no filesystem at all — the Downloads
/// provider, a cloud document provider — simply fail the probe, which is the
/// refusal working.
///
/// Either way the local root is an absolute path, so it is safe to use
/// unexpanded: `Location.expandedPath` — which throws when `HOME` is unset,
/// as it is on a mobile head — is never called here.
///
/// A picked folder lasts the visit unless the run is saved: the
/// saved-profile work is here now, and [start] is what stores a replica
/// root — in a [SyncProfile], when the run is given a name — so a folder
/// picked once comes back pre-selected the next time its profile is
/// opened. Nothing persists it for a run left unnamed; that run was a
/// one-off.
///
/// **The remote root is sent exactly as typed, never expanded.** The desktop
/// resolves `~` in its own environment (`ReplicaSpec.rootPath`,
/// `_specFor` in `lib/cli/agents/connected_replicas.dart`), and must have
/// run `dsync pair grant <name> <root>` for that path as it expands there.
/// [start] only checks that the text is a plain path a desktop could have
/// granted: not a `peer://`, `ssh://` or `host:path` location, because those
/// are the head's own vocabulary and the desktop would parse the remainder
/// as a root it has not granted.
///
/// **A refusal says "not granted", and nothing about the path.** When the
/// desktop refuses the root, the reply is deliberately uninformative
/// (SPEC §4.4; `UnauthorizedReplicaRootException` in
/// `lib/dsync_core/agent/agent_listener.dart`): "does not exist", "could not
/// be read" and "not on your list" are made indistinguishable on purpose,
/// so the peer that asked cannot probe a desktop's filesystem. The head
/// genuinely cannot tell which it was, and [remoteRootNotGrantedMessage] —
/// what the Run feature shows for that reply — must not be "improved" into
/// claiming the path does or does not exist; either would fabricate. A
/// pairing with no agreed roots at all is surfaced up front
/// (`RunSetupPeerLoaded.grantHint`) as the hint it is, not as a check.
///
/// **Dry run is opt-in: the switch defaults OFF, a constant.** A dry run
/// is something the user asks for per run ([setDryRun]), and the choice is
/// not remembered — [load] resets it with the rest of the visit. This
/// gives up SPEC §11.3's "show a plan before the first sync applies"
/// safety on the head: an earlier default derived ON from the absence of
/// an archive for the `(local root, peer device id, remote root)` triple,
/// and in practice read as "always on", because a dry run commits nothing,
/// so the archive that would have flipped the default never appeared until
/// an applying run — precisely the run the switch was in the way of. If
/// the first-sync safety is wanted back, it belongs as a confirmation on
/// the plan the Run page already shows — the point where the head knows
/// what would change — not as a pre-filled switch guessing from an
/// archive file.
class RunSetupController {
  RunSetupController(this.app, {required this.picker});

  final AppController app;

  /// The platform folder chooser and its grant. A dependency rather than a
  /// direct plugin call, per the controller role in `app_scope.dart`: a test
  /// hands over a fake that returns a path in a temp directory.
  final FolderPicker picker;

  /// The view state this controller renders into; owned here, disposed here.
  final RunSetupViewState state = RunSetupViewState();

  String? _peerDeviceId;

  /// The saved profile this form was opened from, or `null` on a blank
  /// one — what an edit saves back over, so renaming a run or retyping its
  /// remote root updates the one profile instead of saving a second beside
  /// it. Set by [load], cleared with it.
  String? _profileId;

  /// The folders picked through the chooser this visit, in the order they
  /// were picked. Reset by [load], like every other per-visit choice.
  final List<String> _pickedRoots = [];

  /// Reads what the page was opened for — the device the Devices page
  /// named, or the saved profile the home list named, via [source] — and
  /// lists the folders that can be a local replica. A device id that
  /// matches nothing, or a profile id that names a deleted profile, is
  /// rendered as [RunSetupPeerMissing], not thrown.
  ///
  /// A profile's values pre-fill the form: its local root is selected
  /// (added to the visit's picks first, so a root chosen in an earlier
  /// visit is listed again) and its name and remote root go out as
  /// [RunSetupViewState.prefill] for the page's text fields. Its id is kept
  /// in [_profileId] for [start]. What is *not* carried over is the
  /// per-run state: the dry-run switch resets, and the address field stays
  /// empty — the cached address is what empty means, and the profile does
  /// not save one (SPEC §4.4's hatch is per run).
  ///
  /// Starts a visit: the selection, the typed remote root and the dry-run
  /// choice are this device's, not carried over from the last one opened.
  Future<void> load(RunSetupSource source) async {
    _pickedRoots.clear();
    state.recordDryRun(false);
    state.recordFieldErrors(localFolder: null, remoteRoot: null, address: null);
    state.recordNewFolderError(null);
    state.recordFolderAccessError(null);
    state.recordOutcome(const RunSetupIdle());
    state.recordPeer(const RunSetupPeerLoading());
    state.recordPrefill(null);

    final String deviceId;
    String? profileLocalRoot;
    switch (source) {
      case RunSetupFromDevice(deviceId: final id):
        _profileId = null;
        deviceId = id;
      case RunSetupFromProfile(:final profileId):
        final profile = await (await app.profiles).byId(profileId);
        if (profile == null) {
          _profileId = null;
          state.recordPeer(
            RunSetupPeerMissing(
              'No saved profile has the id $profileId any more. Go back to '
              'the home list and pick one that is still saved.',
            ),
          );
          return;
        }
        deviceId = profile.peerDeviceId;
        _profileId = profile.id;
        profileLocalRoot = profile.localRootPath;
        _pickedRoots.add(profileLocalRoot);
        state.recordPrefill(
          RunSetupPrefill(
            profileName: profile.name,
            remoteRoot: profile.remoteRootPath,
          ),
        );
    }
    final device = await (await app.pairedDevices).byDeviceId(deviceId);
    if (device == null) {
      _peerDeviceId = null;
      state.recordPeer(
        RunSetupPeerMissing(
          'No paired device has the id $deviceId any more. Go back and pick '
          'one that is still paired.',
        ),
      );
      return;
    }
    _peerDeviceId = device.deviceId;
    state.recordPeer(
      RunSetupPeerLoaded(
        name: device.name,
        grantHint: device.agreedReplicaRoots.isEmpty
            ? '${device.name} has not granted this device any replica root '
                  'yet. On it, run `dsync pair grant <this device> <root>` '
                  'first, then type that root here.'
            : null,
      ),
    );
    await _listLocalFolders(selected: profileLocalRoot);
  }

  /// Picks [path] from `RunSetupViewState.localFolders`, or nothing.
  void selectLocalFolder(String? path) {
    state.recordLocalFolders(state.localFolders, selected: path);
    state.recordOutcome(const RunSetupIdle());
  }

  /// Opens the platform folder chooser and, if the user picks a folder,
  /// proves this head can read and write it before offering it as a replica
  /// root and selecting it.
  ///
  /// A dismissed chooser changes nothing. A folder that fails the probe —
  /// even after the grant the probe's failure prompts for — is not added:
  /// `RunSetupViewState.folderAccessError` carries the reason and the page
  /// raises it, with the way to fix it, over a form that still holds
  /// whatever was selected before. See the class doc comment for why the
  /// verdict is a filesystem probe rather than a permission check.
  Future<void> pickLocalFolder() async {
    state.recordFolderAccessError(null);
    final String? picked;
    try {
      picked = await picker.pick();
    } catch (error) {
      // A platform channel that fails is not a folder the user chose badly.
      state.recordFolderAccessError(
        'Could not open the folder chooser: '
        '$error',
      );
      return;
    }
    if (picked == null) return;

    var refusal = await _accessRefusal(picked);
    if (refusal != null && await picker.requestAccess()) {
      refusal = await _accessRefusal(picked);
    }
    if (refusal != null) {
      state.recordFolderAccessError(refusal);
      return;
    }

    if (!_pickedRoots.contains(picked)) _pickedRoots.add(picked);
    await _listLocalFolders(selected: picked);
    state.recordOutcome(const RunSetupIdle());
  }

  /// Opens the OS settings page that grants access to folders outside the
  /// app's own container — what the page's snackbar offers after a refusal.
  Future<void> openAccessSettings() => picker.openSettings();

  /// Creates `<documentsDir>/<name>` and selects it. [name] is one path
  /// segment — no separator, not `.` or `..` — because the folder must sit
  /// directly under the documents directory for the restriction the class
  /// doc comment describes to hold; anything else is a field error.
  Future<void> createLocalFolder(String name) async {
    final folder = name.trim();
    if (folder.isEmpty) {
      state.recordNewFolderError('Give the new folder a name.');
      return;
    }
    if (folder == '.' || folder == '..' || folder.contains('/')) {
      state.recordNewFolderError(
        'A folder name cannot contain `/` or be `.` or `..`.',
      );
      return;
    }
    final paths = await app.paths;
    try {
      await Directory(p.join(paths.documentsDir, folder)).create();
    } on FileSystemException catch (e) {
      state.recordNewFolderError('Could not create $folder: ${e.message}');
      return;
    }
    state.recordNewFolderError(null);
    await _listLocalFolders(selected: p.join(paths.documentsDir, folder));
    state.recordOutcome(const RunSetupIdle());
  }

  /// A keystroke in the remote root field: the last attempt's outcome is
  /// stale. Validation waits for [start].
  void remoteRootChanged(String text) {
    state.recordOutcome(const RunSetupIdle());
  }

  /// The user moved the dry-run switch: this run is a dry one iff they
  /// turned it on. The next visit starts over — see the class doc comment.
  void setDryRun(bool dryRun) {
    state.recordDryRun(dryRun);
  }

  /// Validates every field and, when all hold, records a [RunSetupStarted]
  /// carrying the one [RunRequest] this page produces — and, when
  /// [profileName] names it, saves the run as a [SyncProfile] for the home
  /// list. Saving happens here and only here, on the one path where every
  /// field has validated, so a profile is never saved for a run that could
  /// not start; an empty [profileName] saves nothing, which is what a
  /// one-off run leaves blank.
  ///
  /// A form opened from a profile saves over that profile's id — renaming
  /// it or retyping its remote root updates the one entry — and a blank
  /// form saves under a fresh [ReplicaConnector.profileIdFor] derivation
  /// over the triple, the id the archive and lock will be keyed under when
  /// this request runs. The per-run choices are not saved: [address] is
  /// SPEC §4.4's hatch, and the dry-run switch is per run.
  ///
  /// [address] is SPEC §4.4's manual re-entry hatch — `host` or
  /// `host:port`, empty for the cached address. The port range is
  /// `PeerAddress`'s rule, refused at construction; it is not re-checked
  /// here. [remoteRoot] is validated as the class doc comment says and
  /// carried unexpanded.
  Future<void> start({
    required String remoteRoot,
    required String address,
    required String profileName,
  }) async {
    final peer = state.peer;
    if (peer is! RunSetupPeerLoaded) {
      state.recordOutcome(
        const RunSetupFailed('Wait for the device to load, then try again.'),
      );
      return;
    }
    final peerDeviceId = _peerDeviceId;
    if (peerDeviceId == null) {
      state.recordOutcome(
        const RunSetupFailed('Wait for the device to load, then try again.'),
      );
      return;
    }

    final localRootPath = state.selectedLocalFolder;
    final remote = remoteRoot.trim();
    PeerAddress? addressOverride;
    String? addressError;
    try {
      addressOverride = _parseAddress(address);
    } on FormatException catch (e) {
      addressError = e.message;
    }
    final localFolderError = localRootPath == null
        ? _localFolderRequired
        : null;
    final remoteRootError = _remoteRootError(remote);
    state.recordFieldErrors(
      localFolder: localFolderError,
      remoteRoot: remoteRootError,
      address: addressError,
    );
    if (localRootPath == null ||
        remoteRootError != null ||
        addressError != null) {
      state.recordOutcome(const RunSetupIdle());
      return;
    }

    state.recordOutcome(const RunSetupStarting());
    try {
      // On demand: a folder listed a moment ago may have been removed by a
      // file manager since, and a missing local root is not a run.
      await Directory(localRootPath).create(recursive: true);
    } on FileSystemException catch (e) {
      state.recordOutcome(
        RunSetupFailed('Could not open $localRootPath: ${e.message}'),
      );
      return;
    }
    final request = RunRequest(
      localRootPath: localRootPath,
      deviceName: peer.name,
      peerDeviceId: peerDeviceId,
      remoteRootPath: remote,
      addressOverride: addressOverride,
      // The same default the CLI takes when no `--jobs` is given
      // (`lib/cli/agents/connected_replicas.dart`).
      jobs: Scanner().jobs,
      dryRun: state.dryRun,
    );
    final name = profileName.trim();
    if (name.isNotEmpty) {
      await app.upsertProfile(
        SyncProfile(
          id:
              _profileId ??
              ReplicaConnector.profileIdFor(
                localRootPath: localRootPath,
                peerDeviceId: peerDeviceId,
                remoteRootPath: remote,
              ),
          name: name,
          localRootPath: localRootPath,
          peerDeviceId: peerDeviceId,
          remoteRootPath: remote,
          jobs: request.jobs,
        ),
      );
    }
    state.recordOutcome(RunSetupStarted(request));
  }

  /// The documents directory's own folders, by name, then this visit's
  /// picked ones, by whole path. A picked folder that happens to sit under
  /// the documents directory is listed once, as its name.
  Future<void> _listLocalFolders({required String? selected}) async {
    final documents = Directory((await app.paths).documentsDir);
    await documents.create(recursive: true);
    final own = [
      await for (final entry in documents.list(followLinks: false))
        if (entry is Directory)
          LocalFolderChoice(path: entry.path, label: p.basename(entry.path)),
    ]..sort((a, b) => a.label.compareTo(b.label));
    final paths = own.map((choice) => choice.path).toSet();
    final choices = [
      ...own,
      for (final root in _pickedRoots)
        if (paths.add(root)) LocalFolderChoice(path: root, label: root),
    ];
    state.recordLocalFolders(
      choices,
      selected: paths.contains(selected) ? selected : null,
    );
  }

  /// Why [path] cannot be a replica root, or `null` when it can — see
  /// [folderAccessRefusal], whose probe this is and which the profiles home
  /// re-runs over every saved profile's local root.
  Future<String?> _accessRefusal(String path) => folderAccessRefusal(path);

  void dispose() => state.dispose();
}

/// The line the Run feature shows when the desktop's reply to the root was
/// SPEC §4.4's uninformative refusal. Says the path was not granted and
/// nothing else — see `RunSetupController`'s doc comment for why it must
/// not say whether the path exists.
String remoteRootNotGrantedMessage({
  required String deviceName,
  required String remoteRoot,
}) =>
    '$deviceName has not granted this path to this device. On it, run '
    '`dsync pair grant <this device> $remoteRoot` for the exact path as it '
    'expands there, then start again.';

/// `host` or `host:port` as a [PeerAddress], `null` for empty text. The
/// host and port rules are `PeerAddress`'s; only "the port is not a number"
/// is decided here, because the constructor takes an `int`.
PeerAddress? _parseAddress(String text) {
  final trimmed = text.trim();
  if (trimmed.isEmpty) return null;
  final colon = trimmed.lastIndexOf(':');
  if (colon < 0) return PeerAddress(host: trimmed);
  final port = int.tryParse(trimmed.substring(colon + 1));
  if (port == null) {
    throw FormatException('Port must be a number: ${trimmed.substring(colon)}');
  }
  return PeerAddress(host: trimmed.substring(0, colon), port: port);
}

/// The remote root field's validation line, or `null`.
String? _remoteRootError(String remote) {
  if (remote.isEmpty) return _remoteRootRequired;
  final Location location;
  try {
    location = Location.parse(remote);
  } on FormatException catch (e) {
    return e.message;
  }
  if (location.host != null) return _remoteRootNotAPath;
  return null;
}

const _localFolderRequired = 'Pick a folder on this device, or create one.';
const _remoteRootRequired =
    'Type the folder on the desktop, as it was granted there.';
const _remoteRootNotAPath =
    'Type a plain path on the desktop, such as ~/notes — the device is '
    'already chosen, so no `peer://`, `ssh://` or `host:` prefix.';
