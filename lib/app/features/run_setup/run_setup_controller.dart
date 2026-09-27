import '../../app_controller.dart';
import '../../core_link/models/core_failure.dart';
import '../../core_link/models/entry_draft.dart';
import '../../core_link/models/paired_device_info.dart';
import '../../core_link/models/profile_draft.dart';
import '../../core_link/models/profile_entry.dart';
import '../../core_link/models/root_kind.dart';
import '../../core_link/models/run_target.dart';
import '../../run_request.dart';
import 'folder_picker.dart';
import 'run_setup_view_state.dart';

/// Input methods of the Run setup page: building the two locations a run
/// needs, blank or from a saved profile (SPEC §2, §4.4, §11.2, §12).
///
/// Takes the [AppController] it borrows the application — and through it
/// the core — from as a constructor argument, per the controller role in
/// `app_scope.dart`. It starts nothing: [start] validates and builds a
/// [RunRequest] — the only place one is constructed — and the Run feature
/// is what asks the core to run it.
///
/// **The local side is one folder, and the user names it.** There is a
/// single way in — the platform's own folder chooser ([pickLocalFolder]) —
/// so a replica lands where the user pointed and where a file manager can
/// reach it. Which folder to sync is the user's to state.
///
/// A picked folder is *checked*, not trusted: the core lists it and writes
/// and deletes one entry in it (SPEC §3) before the form takes it as the
/// root — exactly what a scan and a write will do to it — so a folder that
/// fails is refused here, with a line the page raises as a snackbar, rather
/// than mid-run. On Android the chooser's own grant covers the
/// `content://` tree URI it returns and *not* the path that URI converts
/// to, which is openable only under All-files access
/// (`MANAGE_EXTERNAL_STORAGE`), so a failed check is met by asking for that
/// grant once (`FolderPicker.requestAccess`) and checking again. There is
/// deliberately no fallback to a folder the user did not choose.
///
/// A picked folder lasts the visit unless the run is saved: [start] stores
/// it in a profile when the run is given a name, so a folder picked once
/// comes back as the form's value the next time its profile is opened.
///
/// **The remote root is sent exactly as typed, never expanded.** The
/// desktop resolves `~` in its own environment and must have granted that
/// path as it expands there. Whether it is a plain path at all is the
/// core's to refuse when the run starts or the profile is saved.
///
/// **A refusal says "not granted", and nothing about the path.** When the
/// desktop refuses the root, the reply is deliberately uninformative
/// (SPEC §4.4): "does not exist", "could not be read" and "not on your
/// list" are indistinguishable on purpose, so the peer that asked cannot
/// probe a desktop's filesystem. That refusal, shown by the Run page in the
/// core's words, is the *only* place the head learns a root is not granted.
///
/// **Dry run is opt-in: the switch defaults OFF, a constant.** A dry run
/// is something the user asks for per run ([setDryRun]), and the choice is
/// not remembered — [load] resets it with the rest of the visit.
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
  /// it. Set by [load], and by a save.
  String? _profileName;

  /// The loaded profile's scan concurrency, kept so an edit saved from the
  /// form does not drop it (the form has no field for it).
  int? _profileJobs;

  /// Where the last refused pick stands — kept so the user who grants
  /// All-files access in Settings does not have to pick the folder again.
  /// See [recheckAfterSettings].
  _RefusedFolder _refused = const _NothingRefused();

  /// Reads what the page was opened for — the device the Devices page
  /// named, or the saved profile the home list named, via [source]. A
  /// device id that matches nothing, or a profile name that names a deleted
  /// profile, is rendered as [RunSetupPeerMissing], not thrown.
  ///
  /// A profile's values pre-fill the form: its local root becomes the
  /// form's chosen folder, and its name and remote root go out as
  /// [RunSetupViewState.prefill] for the page's text fields. What is *not*
  /// carried over is the per-run state: the dry-run switch resets, and the
  /// address field stays empty — the cached address is what empty means.
  ///
  /// Starts a visit: the chosen folder, the typed remote root and the
  /// dry-run choice are this device's, not carried over from the last one
  /// opened.
  Future<void> load(RunSetupSource source) async {
    state.recordLocalRoot(null);
    state.recordDryRun(false);
    state.recordIgnorePatterns(const []);
    state.recordFieldErrors(localFolder: null, remoteRoot: null, address: null);
    state.recordFolderAccessError(null);
    state.recordOutcome(const RunSetupIdle());
    state.recordPeer(const RunSetupPeerLoading());
    state.recordPrefill(null);
    _profileName = null;
    _profileJobs = null;
    _peerDeviceId = null;
    _refused = const _NothingRefused();

    try {
      final String deviceId;
      switch (source) {
        case RunSetupFromDevice(deviceId: final id):
          deviceId = id;
        case RunSetupFromProfile(:final profileName):
          final profile = (await app.core.listProfiles())
              .whereType<HeadProfile>()
              .where((profile) => profile.name == profileName)
              .firstOrNull;
          if (profile == null) {
            state.recordPeer(
              RunSetupPeerMissing(
                'No saved run is called "$profileName" any more. Go back to '
                'the home list and pick one that is still saved.',
              ),
            );
            return;
          }
          // The form edits the first entry for now.
          final first = profile.entries.first;
          deviceId = profile.peerDeviceId;
          _profileName = profile.name;
          _profileJobs = profile.jobs;
          state.recordLocalRoot(first.localRoot);
          state.recordIgnorePatterns(profile.ignorePatterns);
          state.recordPrefill(
            RunSetupPrefill(
              profileName: profile.name,
              remoteRoot: first.remoteRoot,
              lastRunUnfinished: profile.lastRunUnfinished,
            ),
          );
      }
      final device = _deviceWith(deviceId, await app.core.listDevices());
      if (device == null) {
        state.recordPeer(
          RunSetupPeerMissing(
            'No paired device has the id $deviceId any more. Go back and '
            'pick one that is still paired.',
          ),
        );
        return;
      }
      _peerDeviceId = device.deviceId;
      // Last: [RunSetupPeerLoaded] is what the page renders the whole form
      // on, and nothing about this visit is still in flight once it lands.
      state.recordPeer(RunSetupPeerLoaded(name: device.name));
    } on CoreFailure catch (e) {
      state.recordPeer(RunSetupPeerMissing(e.message));
    }
  }

  static PairedDeviceInfo? _deviceWith(
    String deviceId,
    List<PairedDeviceInfo> devices,
  ) {
    for (final device in devices) {
      if (device.deviceId == deviceId) return device;
    }
    return null;
  }

  /// Opens the platform folder chooser and, if the user picks a folder,
  /// has the core prove it usable before taking it as the local replica
  /// root. A dismissed chooser changes nothing. A folder that fails — even
  /// after the grant its failure prompts for — is not taken:
  /// `RunSetupViewState.folderAccessError` carries the reason.
  ///
  /// A refused folder is kept, not dropped: [openAccessSettings] and
  /// [recheckAfterSettings] take it once the grant is given. A new pick
  /// replaces it, whatever it turns out to be.
  Future<void> pickLocalFolder() async {
    _refused = const _NothingRefused();
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

    final String? refusal;
    try {
      refusal = await _usableRefusal(picked);
    } on CoreFailure catch (e) {
      state.recordFolderAccessError(e.message);
      return;
    }
    if (refusal != null) {
      _refused = _FolderRefused(picked);
      state.recordFolderAccessError(refusal);
      return;
    }

    state.recordLocalRoot(picked);
    state.recordOutcome(const RunSetupIdle());
  }

  /// The core's refusal of [path], asking for the All-files grant once and
  /// checking again when the first check refuses.
  Future<String?> _usableRefusal(String path) async {
    final refusal = await app.core.checkFolder(path, RootKind.folder);
    if (refusal == null || !await picker.requestAccess()) return refusal;
    return app.core.checkFolder(path, RootKind.folder);
  }

  /// Opens the OS settings page that grants access to folders outside the
  /// app's own container — what the page's snackbar offers after a refusal.
  /// The refused folder then waits for [recheckAfterSettings].
  Future<void> openAccessSettings() {
    if (_refused case _FolderRefused(:final path)) {
      _refused = _AwaitingGrant(path);
    }
    return picker.openSettings();
  }

  /// The app is back from the Settings page [openAccessSettings] opened:
  /// the core checks the refused folder again (a running process sees a
  /// fresh grant), and the form takes it if the check passes. A folder
  /// still refused keeps its refusal — the core's line, in
  /// `RunSetupViewState.folderAccessError` — and waits for the next trip
  /// to Settings. Does nothing unless Settings was opened over a refusal,
  /// and a pick made meanwhile wins over the answer.
  ///
  /// Answers whether the check's verdict was recorded — `false` when there
  /// was nothing to check, or a newer pick overtook it and speaks for
  /// itself.
  Future<bool> recheckAfterSettings() async {
    final waiting = _refused;
    if (waiting is! _AwaitingGrant) return false;
    state.recordFolderAccessError(null);
    String? refusal;
    try {
      refusal = await app.core.checkFolder(waiting.path, RootKind.folder);
    } on CoreFailure catch (e) {
      refusal = e.message;
    }
    if (!identical(_refused, waiting)) return false;
    if (refusal != null) {
      _refused = _FolderRefused(waiting.path);
      state.recordFolderAccessError(refusal);
      return true;
    }
    _refused = const _NothingRefused();
    state.recordLocalRoot(waiting.path);
    state.recordOutcome(const RunSetupIdle());
    return true;
  }

  /// A keystroke in the remote root field: the last attempt's outcome is
  /// stale. Validation waits for [start].
  void remoteRootChanged(String text) {
    state.recordOutcome(const RunSetupIdle());
  }

  /// The user moved the dry-run switch: this run is a dry one iff they
  /// turned it on. The next visit starts over.
  void setDryRun(bool dryRun) {
    state.recordDryRun(dryRun);
  }

  /// The Filters page came back with [patterns] — SPEC §9 `ignore` globs,
  /// each already checked where it was written (`FiltersController`). They
  /// travel with both ways out of this page — the run applies them, and
  /// the profile saves them.
  void setIgnorePatterns(List<String> patterns) {
    state.recordIgnorePatterns(patterns);
    state.recordOutcome(const RunSetupIdle());
  }

  /// Validates every field and, when all hold, records a [RunSetupStarted]
  /// carrying the one [RunRequest] this page produces — and, when
  /// [profileName] names it, saves the run as a profile for the home list
  /// first and runs that profile. An empty [profileName] saves nothing and
  /// runs the pair as a one-off.
  ///
  /// [address] is SPEC §4.4's manual re-entry hatch — `host` or
  /// `host:port`, empty for the cached address; the core reads it when the
  /// run starts. The per-run choices are not saved.
  Future<void> start({
    required String remoteRoot,
    required String address,
    required String profileName,
  }) async {
    final form = _validate(remoteRoot: remoteRoot);
    if (form == null) return;

    // No root is created here: the core creates a first sync's folder
    // itself, and refuses one that went missing after it synced —
    // creating it here would pass it off as emptied.
    state.recordOutcome(const RunSetupStarting());
    final name = profileName.trim();
    if (name.isNotEmpty && !await _saveProfile(form, name)) return;
    final typed = address.trim();
    state.recordOutcome(
      RunSetupStarted(
        RunRequest(
          target: name.isEmpty
              ? DraftTarget(form.draft)
              : SavedProfileTarget(name),
          localRootPath: form.entry.localRoot,
          deviceName: form.deviceName,
          remoteRootPath: form.entry.remoteRoot,
          address: typed.isEmpty ? null : typed,
          dryRun: state.dryRun,
        ),
      ),
    );
  }

  /// Saves the form as a profile and stops there — what renaming a saved
  /// run, or fixing its remote root, needs when the user is not committing
  /// to a sync. The same validation [start] applies; the one rule only this
  /// path has is that a profile needs a name.
  Future<void> save({
    required String remoteRoot,
    required String address,
    required String profileName,
  }) async {
    final form = _validate(remoteRoot: remoteRoot);
    if (form == null) return;
    final name = profileName.trim();
    if (name.isEmpty) {
      state.recordOutcome(const RunSetupFailed(_profileNameRequired));
      return;
    }

    state.recordOutcome(const RunSetupStarting());
    if (await _saveProfile(form, name)) {
      state.recordOutcome(const RunSetupSaved());
    }
  }

  /// Writes [form] as the profile [name] — over the profile this form was
  /// opened from, renamed when the name changed — and remembers the name,
  /// so a second save in the same visit updates the entry the first one
  /// made. A refusal (a name that is not file-safe, a remote root that is
  /// not a plain path) is the outcome line, and answers `false`.
  Future<bool> _saveProfile(_ValidatedForm form, String name) async {
    try {
      await app.saveProfile(name, form.draft, replacing: _profileName);
    } on CoreFailure catch (e) {
      state.recordOutcome(RunSetupFailed(e.message));
      return false;
    }
    _profileName = name;
    return true;
  }

  /// The one validation pass, shared by [start] and [save] so the two
  /// cannot drift: the loaded peer, the chosen local folder and the typed
  /// remote root, as a single value when all of them hold. Records every
  /// field's line either way, and answers `null` — with the outcome reset —
  /// when any of them did not.
  _ValidatedForm? _validate({required String remoteRoot}) {
    final peer = state.peer;
    final peerDeviceId = _peerDeviceId;
    if (peer is! RunSetupPeerLoaded || peerDeviceId == null) {
      state.recordOutcome(
        const RunSetupFailed('Wait for the device to load, then try again.'),
      );
      return null;
    }

    final localRootPath = state.localRoot;
    final remote = remoteRoot.trim();
    final localFolderError = localRootPath == null
        ? _localFolderRequired
        : null;
    final remoteRootError = remote.isEmpty ? _remoteRootRequired : null;
    state.recordFieldErrors(
      localFolder: localFolderError,
      remoteRoot: remoteRootError,
      address: null,
    );
    if (localRootPath == null || remoteRootError != null) {
      state.recordOutcome(const RunSetupIdle());
      return null;
    }
    final entry = EntryDraft(localRoot: localRootPath, remoteRoot: remote);
    return _ValidatedForm(
      deviceName: peer.name,
      entry: entry,
      draft: ProfileDraft(
        peerDeviceId: peerDeviceId,
        entries: [entry],
        jobs: _profileJobs,
        ignorePatterns: state.ignorePatterns,
      ),
    );
  }

  void dispose() => state.dispose();
}

/// The life of a folder the core refused, as [RunSetupController] keeps
/// it: nothing refused, refused, or refused with Settings opened over it —
/// the one case a return to the app re-checks.
sealed class _RefusedFolder {
  const _RefusedFolder();
}

final class _NothingRefused extends _RefusedFolder {
  const _NothingRefused();
}

final class _FolderRefused extends _RefusedFolder {
  const _FolderRefused(this.path);

  final String path;
}

final class _AwaitingGrant extends _RefusedFolder {
  const _AwaitingGrant(this.path);

  final String path;
}

/// What [RunSetupController._validate] answers when every field holds.
class _ValidatedForm {
  const _ValidatedForm({
    required this.deviceName,
    required this.entry,
    required this.draft,
  });

  final String deviceName;

  /// The one entry the form edits, also [draft]'s only entry.
  final EntryDraft entry;
  final ProfileDraft draft;
}

const _localFolderRequired = 'Pick the folder to sync on this device.';
const _profileNameRequired =
    'Name this run to save it — an unnamed run is a one-off, so there is '
    'nothing to save.';
const _remoteRootRequired =
    'Type the folder on the desktop, as it was granted there.';
