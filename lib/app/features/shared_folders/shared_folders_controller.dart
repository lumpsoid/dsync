import '../../app_controller.dart';
import '../../core_link/models/core_failure.dart';
import '../../shared_folder_row.dart';
import '../run_setup/folder_picker.dart';
import 'shared_folders_view_state.dart';

/// Input methods of the Shared folders page: what this host serves, and to
/// whom (SPEC §4.4, §13).
///
/// The Device page answers "what may *this* peer reach here". This one
/// answers the other question — "what does this host serve, and to whom" —
/// over the same store and the same two writes. Sharing one folder with
/// four devices was four typed paths on four pages before this existed,
/// and four chances to type it differently.
///
/// Takes the [AppController] it borrows the application from and the
/// [picker] a chosen folder comes from, per the controller role in
/// `app_scope.dart`.
///
/// **No state of its own beyond the last outcome.** [folders] is an
/// inversion of `AppState.devices`, computed on read in
/// `SharedFolderRow.renderAll`, so a grant made on the Device page — or by
/// `dsync pair grant` behind a refresh — shows here without this feature
/// holding a copy of anything. `AppController.grantRoot` and `revokeRoot`
/// refresh that list on every path, which is what makes a toggle's effect
/// visible without a reload.
///
/// **Every write here is local and one-sided** (SPEC §4.4). Toggling a
/// device on authorizes it to ask; toggling it off means it is refused the
/// next time it asks. The peer is told nothing either way, and nothing here
/// says — or could say — what that peer serves back.
class SharedFoldersController {
  SharedFoldersController(this.app, {required this.picker});

  final AppController app;

  /// The platform's folder chooser, borrowed from Run setup rather than
  /// declared again: it is the same question — which folder on this host —
  /// and what it hands back is a path like any other, stored through the
  /// same call a typed one is.
  ///
  /// Nothing here probes the folder. A grant is authorization, not
  /// reachability: the root a peer will ask for may not exist yet on the
  /// host that serves it (see `DeviceDetailController.picker`).
  final FolderPicker picker;

  /// The view state this controller renders into; owned here, disposed
  /// here.
  final SharedFoldersViewState state = SharedFoldersViewState();

  /// One row per folder this host serves, each carrying every paired device
  /// and whether that device may reach it. Derived on read — see the class
  /// doc for why there is no copy.
  List<SharedFolderRow> get folders =>
      SharedFolderRow.renderAll(app.state.devices);

  /// Every paired device with its toggle off, for a folder that is not
  /// shared with anyone yet: the add flow's device list.
  List<SharedFolderDevice> get devicesForNewFolder =>
      SharedFolderRow.devicesOf(app.state.devices, rootPath: null);

  /// Authorizes [deviceId] to reach [rootPath] — a device toggled on for a
  /// folder this host already serves to someone else. [rootPath] comes off
  /// a row, already expanded, so nothing is parsed here.
  Future<void> share(String deviceId, String rootPath) async {
    await _write(
      () => app.grantRoot(deviceId, rootPath),
      done: 'Sharing $rootPath with ${_nameOf(deviceId)}.',
    );
  }

  /// Withdraws [rootPath] from [deviceId]. The confirmation happens before
  /// this is called.
  ///
  /// When the device losing the grant was the last one holding it, the
  /// folder stops existing as far as the store is concerned — roots are
  /// only ever stored per device, so a folder nobody may reach is a folder
  /// nowhere. It leaves this page with the grant, and the outcome says so
  /// rather than letting a row silently vanish. No file is touched either
  /// way; re-sharing it later is the add flow again.
  Future<void> withdraw(String deviceId, String rootPath) async {
    final wasLast = _isLastShare(rootPath);
    final name = _nameOf(deviceId);
    await _write(
      () => app.revokeRoot(deviceId, rootPath),
      done: wasLast
          ? 'No longer sharing $rootPath with $name. No device may reach '
                'it now, so it is no longer listed here.'
          : 'No longer sharing $rootPath with $name.',
    );
  }

  /// Shares a folder that is not on the page yet: [rawPath] granted to each
  /// of [deviceIds], the core expanding `~` as `dsync pair grant` does.
  ///
  /// At least one device is required, and that is not a nicety. A root is
  /// stored per device; granting it to nobody would write nothing at all,
  /// and the user would be looking at a page that did not gain the folder
  /// they just added with no refusal to explain it.
  ///
  /// Stops at the first device the store refuses — the rest of the list is
  /// re-rendered from the store anyway, and going on would leave the user
  /// with a partly-applied change and one message about it.
  Future<void> shareNewFolder(String rawPath, List<String> deviceIds) async {
    final trimmed = rawPath.trim();
    if (trimmed.isEmpty) {
      state.recordOutcome(const SharedFoldersFailed('Give a folder to share.'));
      return;
    }
    if (deviceIds.isEmpty) {
      state.recordOutcome(
        const SharedFoldersFailed(
          'Choose at least one device. A folder shared with nobody is not '
          'stored anywhere.',
        ),
      );
      return;
    }
    for (final deviceId in deviceIds) {
      await _write(
        () => app.grantRoot(deviceId, trimmed),
        done: deviceIds.length == 1
            ? 'Sharing $trimmed with ${_nameOf(deviceId)}.'
            : 'Sharing $trimmed with ${deviceIds.length} devices.',
      );
      if (state.outcome is SharedFoldersFailed) return;
    }
  }

  /// Opens the platform folder chooser and returns what was picked, or
  /// `null` when the user dismissed it. A chooser that will not open is a
  /// platform channel failing, not a folder chosen badly, and says so on
  /// the page — the dialog that asked stays open on its typed field, which
  /// is the fallback for exactly this.
  Future<String?> chooseFolder() async {
    try {
      return await picker.pick();
    } catch (error) {
      state.recordOutcome(
        SharedFoldersFailed('Could not open the folder chooser: $error'),
      );
      return null;
    }
  }

  /// Whether [rootPath] is granted to exactly one device — the case where
  /// withdrawing it takes the folder off the page. Read before the write,
  /// because afterwards the row is gone.
  bool _isLastShare(String rootPath) {
    var holders = 0;
    for (final row in app.state.devices) {
      if (row.agreedRootLabels.containsKey(rootPath)) holders++;
    }
    return holders == 1;
  }

  /// This host's own name for [deviceId]. A device that is no longer in the
  /// list is one the store is about to refuse the write for, so the phrase
  /// stands in only for the instant between the two, and the refusal —
  /// `core`'s own, naming the id — is what the user ends up reading.
  String _nameOf(String deviceId) {
    for (final row in app.state.devices) {
      if (row.deviceId == deviceId) return row.name;
    }
    return 'that device';
  }

  /// The shape every write here shares: run it, and render either [done] or
  /// the refusal it came back with.
  ///
  /// A store that has gone corrupt since the list was last read lands on
  /// [SharedFoldersFailed] rather than escaping, the same as on the Device
  /// page: the message — `core`'s own, naming the file — is what the user
  /// needs to act on, and the rows already on screen are the last good
  /// ones.
  Future<void> _write(
    Future<String?> Function() op, {
    required String done,
  }) async {
    final String? failure;
    try {
      failure = await op();
    } on CoreFailure catch (e) {
      state.recordOutcome(SharedFoldersFailed(e.message));
      return;
    }
    state.recordOutcome(
      failure == null ? SharedFoldersDone(done) : SharedFoldersFailed(failure),
    );
  }

  void dispose() => state.dispose();
}
