import 'dart:io';

import 'package:dsync/dsync_core/archive/jsonl_archive_store.dart';
import 'package:dsync/dsync_core/models/location.dart';
import 'package:dsync/dsync_core/models/paired_device.dart';
import 'package:dsync/dsync_core/scan/scanner.dart';
import 'package:path/path.dart' as p;

import '../../app_controller.dart';
import '../../run_request.dart';
import '../run/replica_connector.dart';
import 'run_setup_view_state.dart';

/// Input methods of the Run setup page: building the two locations a run
/// needs, with no profile (SPEC §2, §4.4, §11.2, §12).
///
/// Takes the [AppController] it borrows the application from as a
/// constructor argument, per the controller role in `app_scope.dart`. It
/// opens no socket: [start] validates and builds a [RunRequest] — the only
/// place one is constructed — and the Run feature is what connects.
///
/// **The local side is a folder under the app's documents directory, and
/// nothing else.** `Scanner` and `LocalAgent` are plain `dart:io`, and on
/// Android scoped storage that reaches app-private storage and nothing
/// further: what a user grants through the Storage Access Framework is a
/// content URI, not a path `dart:io` can open, so no folder picker could
/// hand this head something the scanner could read. The minimal head
/// therefore restricts the local replica to a directory directly under
/// `AppPaths.documentsDir` — created on demand ([createLocalFolder]) and
/// listed for selection ([load]) — which both platforms let `dart:io` read
/// and write without a grant. SAF stays the separate, larger task SPEC §16
/// defers: it needs a `Scanner`/`Agent` implementation over a content-URI
/// tree, which is `dsync_core` work, not a head concern. The same restriction
/// is what makes the local path safe to use unexpanded: it is absolute by
/// construction, so `Location.expandedPath` — which throws when `HOME` is
/// unset, as it is on a mobile head — is never called here.
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
/// **Dry run defaults ON for the first run against a device** (SPEC §11.3:
/// `status` is `sync --dry-run`). "First run" is derived from the one
/// durable record of a run having been applied: the archive log. The
/// archive is keyed by the `(local root, peer device id, remote root)`
/// triple through `ReplicaConnector.profileIdFor`, and its side-`a` file
/// exists iff a run over that triple has committed something (a dry run
/// commits nothing, so the default stays ON after one). So the default is
/// re-derived whenever the triple changes — [selectLocalFolder],
/// [remoteRootChanged] — until the user moves the switch ([setDryRun]),
/// after which it is theirs. A cheaper rule ("has this device ever
/// connected") would be wrong for a second folder pair against the same
/// desktop, which is a first sync with SPEC's first-sync semantics.
class RunSetupController {
  RunSetupController(this.app);

  final AppController app;

  /// The view state this controller renders into; owned here, disposed here.
  final RunSetupViewState state = RunSetupViewState();

  String? _peerDeviceId;
  String _remoteRoot = '';
  bool _dryRunChosen = false;
  int _dryRunDerivation = 0;

  /// Reads the device the Devices page handed over by id — the destination
  /// loads what it needs — and lists the folders that can be a local
  /// replica. An id that matches nothing is a stale row and is rendered as
  /// [RunSetupPeerMissing], not thrown.
  ///
  /// Starts a visit: the selection, the typed remote root and the dry-run
  /// choice are this device's, not carried over from the last one opened.
  Future<void> load(String deviceId) async {
    _dryRunChosen = false;
    _remoteRoot = '';
    state.recordFieldErrors(localFolder: null, remoteRoot: null, address: null);
    state.recordNewFolderError(null);
    state.recordOutcome(const RunSetupIdle());
    state.recordPeer(const RunSetupPeerLoading());
    final device = await (await app.pairedDevices).byDeviceId(deviceId);
    if (device == null) {
      _peerDeviceId = null;
      state.recordPeer(
        RunSetupPeerMissing(
          'No paired device has the id $deviceId any more. Go back to '
          'Devices and pick one that is still paired.',
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
    await _listLocalFolders(selected: null);
    await _deriveDryRunDefault();
  }

  /// Picks [name] from `RunSetupViewState.localFolders`, or nothing.
  Future<void> selectLocalFolder(String? name) async {
    state.recordLocalFolders(state.localFolders, selected: name);
    state.recordOutcome(const RunSetupIdle());
    await _deriveDryRunDefault();
  }

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
    await _listLocalFolders(selected: folder);
    state.recordOutcome(const RunSetupIdle());
    await _deriveDryRunDefault();
  }

  /// The remote root field's current text, so the dry-run default follows
  /// the triple it is part of. Validation waits for [start].
  Future<void> remoteRootChanged(String text) async {
    _remoteRoot = text;
    state.recordOutcome(const RunSetupIdle());
    await _deriveDryRunDefault();
  }

  /// The user moved the dry-run switch: from here on it is their choice,
  /// and no later derivation overrides it.
  void setDryRun(bool dryRun) {
    _dryRunChosen = true;
    state.recordDryRun(dryRun);
  }

  /// Validates every field and, when all hold, records a [RunSetupStarted]
  /// carrying the one [RunRequest] this page produces.
  ///
  /// [address] is SPEC §4.4's manual re-entry hatch — `host` or
  /// `host:port`, empty for the cached address. The port range is
  /// `PeerAddress`'s rule, refused at construction; it is not re-checked
  /// here. [remoteRoot] is validated as the class doc comment says and
  /// carried unexpanded.
  Future<void> start({
    required String remoteRoot,
    required String address,
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

    final folder = state.selectedLocalFolder;
    final remote = remoteRoot.trim();
    PeerAddress? addressOverride;
    String? addressError;
    try {
      addressOverride = _parseAddress(address);
    } on FormatException catch (e) {
      addressError = e.message;
    }
    final localFolderError = folder == null ? _localFolderRequired : null;
    final remoteRootError = _remoteRootError(remote);
    state.recordFieldErrors(
      localFolder: localFolderError,
      remoteRoot: remoteRootError,
      address: addressError,
    );
    if (folder == null || remoteRootError != null || addressError != null) {
      state.recordOutcome(const RunSetupIdle());
      return;
    }

    state.recordOutcome(const RunSetupStarting());
    final paths = await app.paths;
    final localRootPath = p.join(paths.documentsDir, folder);
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
    state.recordOutcome(
      RunSetupStarted(
        RunRequest(
          localRootPath: localRootPath,
          deviceName: peer.name,
          peerDeviceId: peerDeviceId,
          remoteRootPath: remote,
          addressOverride: addressOverride,
          // The same default the CLI takes when no `--jobs` is given
          // (`lib/cli/agents/connected_replicas.dart`).
          jobs: Scanner().jobs,
          dryRun: state.dryRun,
        ),
      ),
    );
  }

  Future<void> _listLocalFolders({required String? selected}) async {
    final documents = Directory((await app.paths).documentsDir);
    await documents.create(recursive: true);
    final names = [
      await for (final entry in documents.list(followLinks: false))
        if (entry is Directory) p.basename(entry.path),
    ]..sort();
    state.recordLocalFolders(
      names,
      selected: names.contains(selected) ? selected : null,
    );
  }

  /// Re-derives the dry-run default from the current triple, unless the
  /// user has chosen. Two derivations can be in flight when fields change
  /// quickly; only the latest one's answer lands.
  Future<void> _deriveDryRunDefault() async {
    if (_dryRunChosen) return;
    final derivation = ++_dryRunDerivation;
    final peerDeviceId = _peerDeviceId;
    final folder = state.selectedLocalFolder;
    final remote = _remoteRoot.trim();
    if (peerDeviceId == null || folder == null || remote.isEmpty) {
      state.recordDryRun(true);
      return;
    }
    final paths = await app.paths;
    final archive = resolveArchiveLogPath(
      profileId: ReplicaConnector.profileIdFor(
        localRootPath: p.join(paths.documentsDir, folder),
        peerDeviceId: peerDeviceId,
        remoteRootPath: remote,
      ),
      side: 'a',
      platform: paths.stateDirPlatform,
    );
    final applied = await archive.exists();
    if (derivation != _dryRunDerivation || _dryRunChosen) return;
    state.recordDryRun(!applied);
  }

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
